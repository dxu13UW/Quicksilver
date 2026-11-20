defmodule Quicksilver.Integrations.PoeNinjaTest do
  # PLAN I1: poe.ninja client with cache and refresh schedule; PROTOCOL rates.update.
  use Quicksilver.IntegrationsCase, async: true
  @moduletag :capture_log

  alias Quicksilver.Integrations.{Leagues, PoeNinja, PubSub}

  @moduletag :tmp_dir

  defp routes(overrides \\ %{}) do
    Map.merge(
      %{
        Urls.trade_leagues() => {:fixture, "trade_leagues"},
        Urls.poe_ninja_index_state() => {:fixture, "ninja_index_state"},
        Urls.poe_ninja_exchange_overview("Covens", "Currency") =>
          {:fixture, "ninja_exchange_currency_covens"},
        Urls.poe_ninja_stash_overview("Covens", "UniqueAccessory") =>
          {:fixture, "ninja_stash_uniqueaccessory_covens"}
      },
      overrides
    )
  end

  # Leagues loaded (current = Covens), PoeNinja started, rates subscribed.
  defp stack(ctx, routes, ninja_opts \\ []) do
    b = start_base(routes, ctx.tmp_dir)
    start_leagues(b)
    {:ok, _} = Leagues.list(b.leagues)
    PubSub.subscribe(b.pubsub, :rates)
    start_ninja(b, ninja_opts)
    b
  end

  test "rates for the current league, shaped like rates.update", ctx do
    b = stack(ctx, routes())
    assert {:ok, rates} = PoeNinja.rates(b.ninja)

    assert %{
             league: "Covens",
             source: "poe_ninja",
             stale: false,
             divine_chaos: 216.2,
             fetched_at: %DateTime{}
           } = rates

    assert [%{id: "mirror", name: "Mirror of Kalandra"} | _] = rates.rates
    assert Enum.find(rates.rates, &(&1.id == "divine")).divine == 1.0

    # The push goes to subscribers too.
    assert_receive {Quicksilver.Integrations, :rates, ^rates}

    assert %{status: :ok, cached_at: %DateTime{}} =
             eventually(fn ->
               e = health_entry(b.health, "poe_ninja")
               e.status == :ok && e
             end)
  end

  test "fetches index-state, Currency and the item category once, then serves from cache", ctx do
    b = stack(ctx, routes())
    assert {:ok, _} = PoeNinja.rates(b.ninja)
    assert {:ok, _} = PoeNinja.rates(b.ninja)
    PoeNinja.refresh(b.ninja)
    assert {:ok, items} = PoeNinja.items(b.ninja, "UniqueAccessory")
    assert %{league: "Covens", stale: false, items: [%{name: "Foulborn Headhunter"} | _]} = items

    assert requested_urls(b) -- [Urls.trade_leagues()] == [
             Urls.poe_ninja_index_state(),
             Urls.poe_ninja_exchange_overview("Covens", "Currency"),
             Urls.poe_ninja_stash_overview("Covens", "UniqueAccessory")
           ]

    assert {:error, :not_tracked} = PoeNinja.items(b.ninja, "SkillGem")
  end

  test "refetches once the header TTL (max-age - Age) has passed", ctx do
    # floor 0 and a fixture whose remaining freshness is 0 s → due immediately.
    expired = [headers: [{"cache-control", "max-age=60"}, {"age", "60"}]]

    b =
      stack(
        ctx,
        routes(%{
          Urls.poe_ninja_exchange_overview("Covens", "Currency") =>
            {:fixture, "ninja_exchange_currency_covens", expired}
        }),
        floor_ttl_s: 0
      )

    assert {:ok, _} = PoeNinja.rates(b.ninja)
    assert_receive {Quicksilver.Integrations, :rates, _}
    PoeNinja.refresh(b.ninja)
    assert_receive {Quicksilver.Integrations, :rates, _}

    urls = requested_urls(b)
    assert Enum.count(urls, &(&1 == Urls.poe_ninja_exchange_overview("Covens", "Currency"))) == 2
    # Still fresh: not refetched.
    assert Enum.count(urls, &(&1 == Urls.poe_ninja_stash_overview("Covens", "UniqueAccessory"))) ==
             1
  end

  test "a failed refresh serves the cache marked stale (degraded)", ctx do
    currency = Urls.poe_ninja_exchange_overview("Covens", "Currency")
    expired = [headers: [{"cache-control", "max-age=1"}, {"age", "1"}]]

    b =
      stack(
        ctx,
        routes(%{
          currency => [
            {:fixture, "ninja_exchange_currency_covens", expired},
            {:fixture, "ninja_exchange_currency_covens", status: 503}
          ]
        }),
        floor_ttl_s: 0,
        retry_base_s: 0
      )

    assert {:ok, %{stale: false}} = PoeNinja.rates(b.ninja)
    PoeNinja.refresh(b.ninja)

    assert %{status: :degraded, detail: "showing cached data: HTTP 503"} =
             eventually(fn ->
               e = health_entry(b.health, "poe_ninja")
               e.status == :degraded && e
             end)

    assert {:ok, %{stale: true, divine_chaos: 216.2}} = PoeNinja.rates(b.ninja)
  end

  test "no cache and the source is down: unavailable, Health down", ctx do
    b =
      stack(
        ctx,
        routes(%{
          Urls.poe_ninja_exchange_overview("Covens", "Currency") => {:error, :econnrefused}
        })
      )

    assert {:error, :unavailable} = PoeNinja.rates(b.ninja)

    assert %{status: :down, detail: "network error"} =
             eventually(fn ->
               e = health_entry(b.health, "poe_ninja")
               e.status == :down && e
             end)

    # The item category still loaded.
    assert {:ok, _} = PoeNinja.items(b.ninja, "UniqueAccessory")
  end

  test "empty lines are treated as an unsupported type, not as no prices", ctx do
    b =
      stack(
        ctx,
        routes(%{
          Urls.poe_ninja_exchange_overview("Covens", "Currency") =>
            {:fixture, "ninja_exchange_currency_covens", body: &%{&1 | "lines" => []}}
        })
      )

    assert {:error, :unavailable} = PoeNinja.rates(b.ninja)

    assert %{detail: "type not supported by source"} =
             eventually(fn ->
               e = health_entry(b.health, "poe_ninja")
               e.status == :down && e
             end)
  end

  test "leagues poe.ninja doesn't cover are never requested", ctx do
    b = stack(ctx, routes())
    :ok = Leagues.set_current(b.leagues, "Ruthless")
    eventually(fn -> :sys.get_state(b.ninja).league == "Ruthless" end)

    assert {:error, :league_not_covered} = PoeNinja.rates(b.ninja)
    refute Enum.any?(requested_urls(b), &String.contains?(&1, "league=Ruthless"))

    assert %{status: :down, detail: "poe.ninja has no data for Ruthless"} =
             eventually(fn ->
               e = health_entry(b.health, "poe_ninja")
               e.status == :down && e
             end)
  end

  test "a league change pushes cached rates at once; a new league is fetched", ctx do
    hc = "Hardcore Covens"

    b =
      stack(
        ctx,
        routes(%{
          Urls.poe_ninja_exchange_overview(hc, "Currency") =>
            {:fixture, "ninja_exchange_currency_covens"},
          Urls.poe_ninja_stash_overview(hc, "UniqueAccessory") =>
            {:fixture, "ninja_stash_uniqueaccessory_covens"}
        }),
        auto_refresh: true
      )

    assert_receive {Quicksilver.Integrations, :rates, %{league: "Covens"}}, 2_000

    :ok = Leagues.set_current(b.leagues, hc)
    assert_receive {Quicksilver.Integrations, :rates, %{league: ^hc}}, 2_000
    assert Enum.member?(requested_urls(b), Urls.poe_ninja_exchange_overview(hc, "Currency"))

    # Back to Covens: still fresh, so pushed from cache without a request.
    count = length(requested_urls(b))
    :ok = Leagues.set_current(b.leagues, "Covens")
    assert_receive {Quicksilver.Integrations, :rates, %{league: "Covens"}}, 2_000
    Process.sleep(50)
    assert length(requested_urls(b)) == count
  end

  test "rates without a known league", ctx do
    b = start_base(%{Urls.trade_leagues() => {:error, :timeout}}, ctx.tmp_dir)
    start_leagues(b)
    start_ninja(b)
    assert {:error, :no_league} = PoeNinja.rates(b.ninja)
    assert %{status: :idle} = health_entry(b.health, "poe_ninja")
  end

  test "space in league names is encoded as %20" do
    assert Urls.poe_ninja_exchange_overview("Hardcore Covens", "Currency") ==
             "https://poe.ninja/poe1/api/economy/exchange/current/overview?league=Hardcore%20Covens&type=Currency"
  end
end
