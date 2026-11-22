defmodule Quicksilver.Integrations.LeaguesTest do
  # PLAN I2, DASH-2 (league saved and restored), PROTOCOL "Default league".
  use Quicksilver.IntegrationsCase, async: true
  @moduletag :capture_log

  alias Quicksilver.Integrations.{Leagues, PubSub}

  @moduletag :tmp_dir

  defp base(ctx, routes \\ nil) do
    routes = routes || %{Urls.trade_leagues() => {:fixture, "trade_leagues"}}
    start_base(routes, ctx.tmp_dir)
  end

  test "lists PC leagues in source order and defaults to the first one", ctx do
    b = base(ctx)
    PubSub.subscribe(b.pubsub, :league)
    start_leagues(b)

    assert Leagues.current(b.leagues) == nil
    assert {:ok, leagues} = Leagues.list(b.leagues)

    assert Enum.map(leagues, & &1.id) ==
             [
               "Covens",
               "Hardcore Covens",
               "Ruthless Covens",
               "HC Ruthless Covens",
               "Standard",
               "Hardcore",
               "Ruthless",
               "Hardcore Ruthless"
             ]

    assert Leagues.current(b.leagues) == "Covens"
    assert_receive {Quicksilver.Integrations, :league_changed, "Covens"}

    assert %{status: :ok, cached_at: %DateTime{}, detail: nil} =
             eventually(fn ->
               e = health_entry(b.health, "trade_leagues")
               e.status == :ok && e
             end)
  end

  test "serves the cache within the TTL (one request)", ctx do
    b = base(ctx)
    start_leagues(b)
    assert {:ok, _} = Leagues.list(b.leagues)
    assert {:ok, _} = Leagues.list(b.leagues)
    Leagues.refresh(b.leagues)
    assert {:ok, _} = Leagues.list(b.leagues)
    assert requested_urls(b) == [Urls.trade_leagues()]
  end

  test "restores the saved league; set_current saves and broadcasts", ctx do
    b = base(ctx)
    :ok = Quicksilver.Settings.put(b.settings, "league", "Standard")
    start_leagues(b)
    PubSub.subscribe(b.pubsub, :league)

    assert Leagues.current(b.leagues) == "Standard"
    assert {:ok, _} = Leagues.list(b.leagues)
    assert Leagues.current(b.leagues) == "Standard"
    refute_received {Quicksilver.Integrations, :league_changed, _}

    assert :ok = Leagues.set_current(b.leagues, "Hardcore Covens")
    assert_receive {Quicksilver.Integrations, :league_changed, "Hardcore Covens"}
    assert Quicksilver.Settings.get(b.settings, "league", nil) == "Hardcore Covens"

    # Same league again: still :ok and still broadcast (a fresh rates push follows).
    assert :ok = Leagues.set_current(b.leagues, "Hardcore Covens")
    assert_receive {Quicksilver.Integrations, :league_changed, "Hardcore Covens"}

    file = Path.join(ctx.tmp_dir, "settings.json") |> File.read!() |> Jason.decode!()
    assert file["league"] == "Hardcore Covens"
  end

  test "rejects leagues that aren't listed (including other realms' only names)", ctx do
    b = base(ctx)
    start_leagues(b)
    assert {:error, :unavailable} = Leagues.set_current(b.leagues, "Covens")
    assert {:ok, _} = Leagues.list(b.leagues)
    assert {:error, :unknown_league} = Leagues.set_current(b.leagues, "Foo")
    assert {:error, :unknown_league} = Leagues.set_current(b.leagues, "covens")
    assert Quicksilver.Settings.get(b.settings, "league", nil) == nil
  end

  test "a saved league that ended falls back to the default without overwriting it", ctx do
    b = base(ctx)
    :ok = Quicksilver.Settings.put(b.settings, "league", "Settlers")
    PubSub.subscribe(b.pubsub, :league)
    start_leagues(b)
    assert Leagues.current(b.leagues) == "Settlers"
    assert {:ok, _} = Leagues.list(b.leagues)
    assert Leagues.current(b.leagues) == "Covens"
    assert_receive {Quicksilver.Integrations, :league_changed, "Covens"}
    assert Quicksilver.Settings.get(b.settings, "league", nil) == "Settlers"
  end

  test "no list and no saved league: Standard, Health down; then recovers", ctx do
    b = base(ctx, %{Urls.trade_leagues() => [{:error, :timeout}, {:fixture, "trade_leagues"}]})
    PubSub.subscribe(b.pubsub, :league)
    start_leagues(b, retry_base_s: 0)

    assert {:error, :unavailable} = Leagues.list(b.leagues)
    assert Leagues.current(b.leagues) == "Standard"
    assert_receive {Quicksilver.Integrations, :league_changed, "Standard"}

    assert %{status: :down, detail: "network timeout"} =
             eventually(fn ->
               e = health_entry(b.health, "trade_leagues")
               e.status == :down && e
             end)

    # The retry is allowed (retry_base_s: 0); the fallback gives way to the default.
    assert {:ok, _} = Leagues.list(b.leagues)
    assert Leagues.current(b.leagues) == "Covens"
    assert_receive {Quicksilver.Integrations, :league_changed, "Covens"}
  end

  test "a failed refresh keeps serving the old list (degraded)", ctx do
    b =
      base(ctx, %{
        Urls.trade_leagues() => [
          {:fixture, "trade_leagues"},
          {:fixture, "trade_leagues", status: 503}
        ]
      })

    start_leagues(b, ttl_s: 0)

    assert {:ok, leagues} = Leagues.list(b.leagues)
    Leagues.refresh(b.leagues)

    assert %{status: :degraded, detail: "HTTP 503"} =
             eventually(fn ->
               e = health_entry(b.health, "trade_leagues")
               e.status == :degraded && e
             end)

    assert {:ok, ^leagues} = Leagues.list(b.leagues)
  end

  test "a failed attempt backs off instead of retrying on every call", ctx do
    b = base(ctx, %{Urls.trade_leagues() => {:error, :econnrefused}})
    start_leagues(b)
    assert {:error, :unavailable} = Leagues.list(b.leagues)
    assert {:error, :unavailable} = Leagues.list(b.leagues)
    assert {:error, :unavailable} = Leagues.list(b.leagues)
    assert length(requested_urls(b)) == 1
  end

  test "auto refresh fetches at startup", ctx do
    b = base(ctx)
    start_leagues(b, auto_refresh: true)
    eventually(fn -> Leagues.current(b.leagues) == "Covens" end)
    assert requested_urls(b) == [Urls.trade_leagues()]
  end
end
