defmodule Quicksilver.Gateway.DashboardTest do
  # PROTOCOL.md "Dashboard": leagues.list, league.set, rates.subscribe/unsubscribe,
  # rates.update. Requirements: DASH-1 (rates table in chaos and divine, with the
  # update time), DASH-2 (league selector, saved and restored; changing the
  # league reloads the rates), NFR-REL-3 (stale/unavailable data), NFR-MNT-1
  # (offline: fixture HTTP or a scripted source, never the network).
  #
  # "stack" tests run the real Leagues/PoeNinja servers on the fixture HTTP
  # adapter (Quicksilver.Test.StackSource); "scripted" tests use
  # Quicksilver.Test.ScriptedSource for outcomes the stack can't easily produce.
  use ExUnit.Case, async: true
  @moduletag :tmp_dir
  @moduletag :capture_log

  import Quicksilver.GatewayCase
  import Quicksilver.IntegrationsCase

  alias Quicksilver.Integrations.{Leagues, PoeNinja, PubSub, Urls}
  alias Quicksilver.Test.{ScriptedSource, StackSource, WSClient}

  @pc_leagues [
    "Covens",
    "Hardcore Covens",
    "Ruthless Covens",
    "HC Ruthless Covens",
    "Standard",
    "Hardcore",
    "Ruthless",
    "Hardcore Ruthless"
  ]

  # --- Setup helpers ------------------------------------------------------------------

  defp routes(overrides \\ %{}) do
    ninja =
      for league <- ["Covens", "Standard"], into: %{} do
        {Urls.poe_ninja_exchange_overview(league, "Currency"),
         {:fixture, "ninja_exchange_currency_covens"}}
      end

    stash =
      for league <- ["Covens", "Standard"], into: %{} do
        {Urls.poe_ninja_stash_overview(league, "UniqueAccessory"),
         {:fixture, "ninja_stash_uniqueaccessory_covens"}}
      end

    %{
      Urls.trade_leagues() => {:fixture, "trade_leagues"},
      Urls.poe_ninja_index_state() => {:fixture, "ninja_index_state"}
    }
    |> Map.merge(ninja)
    |> Map.merge(stash)
    |> Map.merge(overrides)
  end

  # A warm stack: leagues listed (current = Covens), Covens rates cached,
  # poe.ninja refreshing on league changes like in production. Then a gateway
  # on top and one handshaken client.
  defp warm(ctx, opts \\ []) do
    b = start_base(Keyword.get(opts, :routes, routes()), ctx.tmp_dir)
    start_leagues(b)
    {:ok, _} = Leagues.list(b.leagues)
    start_ninja(b, auto_refresh: true)
    {:ok, _} = PoeNinja.rates(b.ninja)
    connect_stack(b, Keyword.get(opts, :gateway, []))
  end

  # A stack where nothing has been fetched yet.
  defp cold(ctx, routes, opts \\ []) do
    b = start_base(routes, ctx.tmp_dir)
    start_leagues(b)
    start_ninja(b)
    connect_stack(b, Keyword.get(opts, :gateway, []))
  end

  defp connect_stack(b, gateway_opts) do
    gw =
      start_gateway!(
        Keyword.merge(
          [health: b.health, settings: b.settings, data_source: {StackSource, b}],
          gateway_opts
        )
      )

    {client, _welcome, _health} = handshake!(gw.port, gw.token)
    b |> Map.merge(gw) |> Map.put(:client, client)
  end

  defp scripted(ctx, funs, gateway_opts \\ []) do
    n = System.unique_integer([:positive])
    pubsub = :"pubsub_#{n}"
    settings = :"settings_#{n}"
    health = :"health_#{n}"

    start_supervised!({PubSub, name: pubsub}, id: pubsub)
    start_supervised!({Quicksilver.Settings, name: settings, dir: ctx.tmp_dir}, id: settings)
    start_supervised!({Quicksilver.Health, name: health}, id: health)

    gw =
      start_gateway!(
        Keyword.merge(
          [
            health: health,
            settings: settings,
            data_source: {ScriptedSource, Map.put(funs, :pubsub, pubsub)}
          ],
          gateway_opts
        )
      )

    {client, _welcome, _health} = handshake!(gw.port, gw.token)
    Map.merge(gw, %{client: client, pubsub: pubsub, settings: settings})
  end

  defp request(client, type, id, payload \\ %{}) do
    :ok = WSClient.send_json(client, %{"type" => type, "id" => id, "payload" => payload})
  end

  # The next frame that isn't a health push.
  defp recv!(client, timeout \\ 2_000) do
    case recv_json!(client, timeout) |> assert_envelope() do
      %{"type" => "health"} -> recv!(client, timeout)
      msg -> msg
    end
  end

  defp assert_error(msg, id, code) do
    assert %{"type" => "error", "id" => ^id, "payload" => %{"code" => ^code} = p} = msg
    assert is_binary(p["message"]) and p["message"] != ""
    msg
  end

  defp subscribers(pubsub), do: Registry.lookup(pubsub, :rates)

  defp assert_rates_payload(payload) do
    assert Map.keys(payload) |> Enum.sort() ==
             ~w(divine_chaos fetched_at league rates source stale)

    assert payload["source"] == "poe_ninja"
    assert payload["fetched_at"] =~ ts_regex()
    assert is_boolean(payload["stale"])
    assert is_number(payload["divine_chaos"])

    rows = payload["rates"]
    assert rows != []

    for row <- rows do
      assert Map.keys(row) |> Enum.sort() ==
               ~w(change_7d chaos divine id name volume_chaos)

      assert is_binary(row["id"]) and is_binary(row["name"])
      assert is_number(row["chaos"]) and is_number(row["divine"])
      assert is_number(row["change_7d"]) or is_nil(row["change_7d"])
      assert is_number(row["volume_chaos"]) or is_nil(row["volume_chaos"])
    end

    chaos = Enum.map(rows, & &1["chaos"])
    assert chaos == Enum.sort(chaos, :desc)
    payload
  end

  # --- leagues.list ---------------------------------------------------------------------

  describe "leagues.list" do
    test "DASH-2: replies leagues.result with PC leagues in source order and the current league",
         ctx do
      s = warm(ctx)
      request(s.client, "leagues.list", "c-2")

      assert %{"type" => "leagues.result", "id" => "c-2", "payload" => payload} = recv!(s.client)
      assert Enum.map(payload["leagues"], & &1["id"]) == @pc_leagues
      assert Enum.all?(payload["leagues"], &(Map.keys(&1) |> Enum.sort() == ["id", "text"]))
      assert payload["current"] == "Covens"
    end

    test "on a cold cache, waits for the first fetch and answers", ctx do
      s = cold(ctx, routes())
      request(s.client, "leagues.list", "c-2")

      assert %{"type" => "leagues.result", "payload" => %{"current" => "Covens"}} =
               recv!(s.client)
    end

    test "upstream_unavailable when the league list can't be fetched", ctx do
      s = cold(ctx, routes(%{Urls.trade_leagues() => {:error, :econnrefused}}))
      request(s.client, "leagues.list", "c-2")
      assert_error(recv!(s.client), "c-2", "upstream_unavailable")
    end

    test "upstream_unavailable when the fetch takes longer than upstream_timeout_ms", ctx do
      gate = {:gate, self(), {:fixture, "trade_leagues"}}

      s =
        cold(ctx, routes(%{Urls.trade_leagues() => gate}), gateway: [upstream_timeout_ms: 200])

      request(s.client, "leagues.list", "c-2")
      assert_receive {:fixture_gate, _pid, _url}, 1_000
      assert_error(recv!(s.client), "c-2", "upstream_unavailable")
    end
  end

  # --- league.set -----------------------------------------------------------------------

  describe "league.set" do
    test "DASH-2: replies league.changed, saves the league, and it is restored after a restart",
         ctx do
      s = warm(ctx)
      request(s.client, "league.set", "c-3", %{"league" => "Standard"})

      assert %{"type" => "league.changed", "id" => "c-3", "payload" => %{"league" => "Standard"}} =
               recv!(s.client)

      assert Quicksilver.Settings.get(s.settings, "league", nil) == "Standard"

      # welcome.league is the active league (PROTOCOL "welcome").
      {_client, welcome, _health} = handshake!(s.port, s.token)
      assert welcome["payload"]["league"] == "Standard"

      # "Next launch": a fresh Leagues server on the same settings file restores
      # it, before and after its list has loaded.
      :ok = stop_supervised(:leagues)
      start_leagues(s)
      {_client, welcome, _health} = handshake!(s.port, s.token)
      assert welcome["payload"]["league"] == "Standard"

      request(s.client, "leagues.list", "c-4")
      assert recv!(s.client)["payload"]["current"] == "Standard"
    end

    test "DASH-2: when subscribed, a fresh rates.update for the new league follows league.changed",
         ctx do
      s = warm(ctx)
      request(s.client, "rates.subscribe", "c-2")
      assert %{"type" => "rates.update", "id" => "c-2"} = recv!(s.client)

      request(s.client, "league.set", "c-3", %{"league" => "Standard"})
      assert %{"type" => "league.changed", "id" => "c-3"} = recv!(s.client)

      assert %{"type" => "rates.update", "id" => nil, "payload" => payload} = recv!(s.client)
      assert payload["league"] == "Standard"
      assert_rates_payload(payload)
    end

    test "setting the same league again still pushes fresh rates (cached)", ctx do
      s = warm(ctx)
      request(s.client, "rates.subscribe", "c-2")
      assert %{"type" => "rates.update"} = recv!(s.client)

      request(s.client, "league.set", "c-3", %{"league" => "Covens"})
      assert %{"type" => "league.changed", "id" => "c-3"} = recv!(s.client)
      assert %{"type" => "rates.update", "id" => nil} = recv!(s.client)
    end

    test "without a subscription no rates.update follows", ctx do
      s = warm(ctx)
      request(s.client, "league.set", "c-3", %{"league" => "Standard"})
      assert %{"type" => "league.changed"} = recv!(s.client)
      refute_frame(s.client, 300)
    end

    test "unknown_league for a league that isn't in the list; nothing is saved", ctx do
      s = warm(ctx)
      request(s.client, "league.set", "c-3", %{"league" => "Foo"})

      msg = assert_error(recv!(s.client), "c-3", "unknown_league")
      assert msg["payload"]["message"] =~ "Foo"
      assert Quicksilver.Settings.get(s.settings, "league", nil) == nil
    end

    test "league ids are matched exactly (case-sensitive)", ctx do
      s = warm(ctx)
      request(s.client, "league.set", "c-3", %{"league" => "covens"})
      assert_error(recv!(s.client), "c-3", "unknown_league")
    end

    test "bad_request for a missing, empty or mistyped league", ctx do
      s = warm(ctx)

      for {payload, n} <- Enum.with_index([%{}, %{"league" => ""}, %{"league" => 7}]) do
        request(s.client, "league.set", "c-#{n}", payload)
        assert_error(recv!(s.client), "c-#{n}", "bad_request")
      end
    end

    test "upstream_unavailable when the league list can't be fetched", ctx do
      s = cold(ctx, routes(%{Urls.trade_leagues() => {:error, :econnrefused}}))
      request(s.client, "league.set", "c-3", %{"league" => "Covens"})
      assert_error(recv!(s.client), "c-3", "upstream_unavailable")
    end

    test "internal when the settings file can't be written", ctx do
      s = scripted(ctx, %{set_league: fn _id -> {:error, {:settings, :eacces}} end})
      request(s.client, "league.set", "c-3", %{"league" => "Covens"})
      msg = assert_error(recv!(s.client), "c-3", "internal")
      refute msg["payload"]["message"] =~ "eacces"
    end
  end

  # --- rates.subscribe / rates.unsubscribe / rates.update ---------------------------------------

  describe "rates" do
    test "DASH-1: rates.subscribe replies rates.update echoing the id, per PROTOCOL", ctx do
      s = warm(ctx)
      request(s.client, "rates.subscribe", "c-5")

      assert %{"type" => "rates.update", "id" => "c-5", "payload" => payload} = recv!(s.client)
      assert_rates_payload(payload)
      assert payload["league"] == "Covens"
      assert payload["stale"] == false
      assert payload["divine_chaos"] == 216.2
      assert Enum.find(payload["rates"], &(&1["id"] == "divine"))["divine"] == 1.0
    end

    test "DASH-1: a cache refresh is pushed as rates.update with id null", ctx do
      s = warm(ctx)
      request(s.client, "rates.subscribe", "c-5")
      assert %{"id" => "c-5"} = recv!(s.client)

      {:ok, rates} = PoeNinja.rates(s.ninja)
      refreshed = %{rates | fetched_at: DateTime.utc_now(), stale: true}
      PubSub.broadcast(s.pubsub, :rates, :rates, refreshed)

      assert %{"type" => "rates.update", "id" => nil, "payload" => payload} = recv!(s.client)
      assert payload["stale"] == true
      assert payload["fetched_at"] == Quicksilver.Time.iso8601_ms(refreshed.fetched_at)
    end

    test "subscribing twice still gives one push per refresh", ctx do
      s = warm(ctx)
      request(s.client, "rates.subscribe", "c-5")
      assert %{"id" => "c-5"} = recv!(s.client)
      request(s.client, "rates.subscribe", "c-6")
      assert %{"type" => "rates.update", "id" => "c-6"} = recv!(s.client)

      {:ok, rates} = PoeNinja.rates(s.ninja)
      PubSub.broadcast(s.pubsub, :rates, :rates, rates)
      assert %{"type" => "rates.update", "id" => nil} = recv!(s.client)
      refute_frame(s.client, 200)
    end

    test "rates.unsubscribe replies rates.unsubscribed and stops the pushes", ctx do
      s = warm(ctx)
      request(s.client, "rates.subscribe", "c-5")
      assert %{"id" => "c-5"} = recv!(s.client)

      request(s.client, "rates.unsubscribe", "c-6")

      assert %{"type" => "rates.unsubscribed", "id" => "c-6", "payload" => payload} =
               recv!(s.client)

      assert payload == %{}
      assert subscribers(s.pubsub) == []

      {:ok, rates} = PoeNinja.rates(s.ninja)
      PubSub.broadcast(s.pubsub, :rates, :rates, rates)
      refute_frame(s.client, 200)
    end

    test "rates.unsubscribe without a subscription still replies rates.unsubscribed", ctx do
      s = warm(ctx)
      request(s.client, "rates.unsubscribe", "c-6")
      assert %{"type" => "rates.unsubscribed", "id" => "c-6"} = recv!(s.client)
    end

    test "the subscription is removed when the socket closes", ctx do
      s = warm(ctx)
      request(s.client, "rates.subscribe", "c-5")
      assert %{"id" => "c-5"} = recv!(s.client)
      assert [{socket_pid, _}] = subscribers(s.pubsub)

      ref = Process.monitor(socket_pid)
      WSClient.close(s.client)
      assert_receive {:DOWN, ^ref, :process, ^socket_pid, _}, 2_000
      assert eventually(fn -> subscribers(s.pubsub) == [] end)
    end

    test "NFR-REL-3: upstream_unavailable when poe.ninja is down with nothing cached; the subscription stays and data is pushed once it arrives",
         ctx do
      down = %{
        Urls.poe_ninja_exchange_overview("Covens", "Currency") => {:error, :econnrefused},
        Urls.poe_ninja_stash_overview("Covens", "UniqueAccessory") => {:error, :econnrefused}
      }

      s = cold(ctx, routes(down))
      request(s.client, "rates.subscribe", "c-5")
      assert_error(recv!(s.client), "c-5", "upstream_unavailable")
      assert [_] = subscribers(s.pubsub)

      PubSub.broadcast(s.pubsub, :rates, :rates, ScriptedSource.sample_rates())
      assert %{"type" => "rates.update", "id" => nil} = recv!(s.client)
    end

    test "upstream_unavailable for a league poe.ninja doesn't cover", ctx do
      b = start_base(routes(), ctx.tmp_dir)
      start_leagues(b)
      {:ok, _} = Leagues.list(b.leagues)
      :ok = Leagues.set_current(b.leagues, "Ruthless Covens")
      start_ninja(b)
      s = connect_stack(b, [])

      request(s.client, "rates.subscribe", "c-5")
      assert_error(recv!(s.client), "c-5", "upstream_unavailable")
    end

    test "upstream_unavailable when no league is known yet", ctx do
      s = scripted(ctx, %{rates: fn _opts -> {:error, :no_league} end})
      request(s.client, "rates.subscribe", "c-5")
      assert_error(recv!(s.client), "c-5", "upstream_unavailable")
    end

    test "the reply comes before a refresh that arrives while it is being prepared", ctx do
      test = self()

      s =
        scripted(ctx, %{
          rates: fn _opts ->
            send(test, {:rates_called, self()})
            receive do: (:go -> {:ok, ScriptedSource.sample_rates("Covens", 216.2)})
          end
        })

      request(s.client, "rates.subscribe", "c-5")
      assert_receive {:rates_called, task}, 1_000
      PubSub.broadcast(s.pubsub, :rates, :rates, ScriptedSource.sample_rates("Covens", 220.0))
      send(task, :go)

      assert %{"type" => "rates.update", "id" => "c-5"} = recv!(s.client)

      assert %{"type" => "rates.update", "id" => nil, "payload" => %{"divine_chaos" => 220.0}} =
               recv!(s.client)
    end

    test "a held refresh identical to the reply isn't sent twice", ctx do
      test = self()

      s =
        scripted(ctx, %{
          rates: fn _opts ->
            send(test, {:rates_called, self()})
            receive do: (:go -> {:ok, ScriptedSource.sample_rates()})
          end
        })

      request(s.client, "rates.subscribe", "c-5")
      assert_receive {:rates_called, task}, 1_000
      PubSub.broadcast(s.pubsub, :rates, :rates, ScriptedSource.sample_rates())
      send(task, :go)

      assert %{"type" => "rates.update", "id" => "c-5"} = recv!(s.client)
      refute_frame(s.client, 200)
    end
  end

  # --- welcome.league (active league) ----------------------------------------------------

  describe "welcome.league" do
    test "DASH-2: with nothing saved, it is the default league once the list is known", ctx do
      s = warm(ctx)
      assert Quicksilver.Settings.get(s.settings, "league", nil) == nil
      {_client, welcome, _health} = handshake!(s.port, s.token)
      assert welcome["payload"]["league"] == "Covens"
    end

    test "with nothing saved and no list yet, it is null", ctx do
      s = cold(ctx, routes())
      {_client, welcome, _health} = handshake!(s.port, s.token)
      assert welcome["payload"]["league"] == nil
    end

    test "a stuck data source can't hold up the handshake: welcome goes out with null", ctx do
      s = scripted(ctx, %{current_league: fn -> Process.sleep(:infinity) end})
      started = System.monotonic_time(:millisecond)
      {_client, welcome, _health} = handshake!(s.port, s.token)
      assert System.monotonic_time(:millisecond) - started < 2_000
      assert welcome["payload"]["league"] == nil
    end
  end

  # --- Rates error push ---------------------------------------------------------------------

  describe "rates error push" do
    defp assert_rates_error(msg, league) do
      assert %{"type" => "error", "id" => nil, "payload" => payload} = msg

      assert %{"code" => "upstream_unavailable", "topic" => "rates", "league" => ^league} =
               payload

      assert is_binary(payload["message"]) and payload["message"] != ""
    end

    test "DASH-2: league.set to a league poe.ninja doesn't cover pushes it after league.changed",
         ctx do
      s = warm(ctx)
      request(s.client, "rates.subscribe", "c-2")
      assert %{"type" => "rates.update", "id" => "c-2"} = recv!(s.client)

      request(s.client, "league.set", "c-3", %{"league" => "Ruthless Covens"})
      assert %{"type" => "league.changed", "id" => "c-3"} = recv!(s.client)
      assert_rates_error(recv!(s.client), "Ruthless Covens")
      refute_frame(s.client, 200)

      # The subscription stays: a later rates.update for that league is pushed.
      PubSub.broadcast(
        s.pubsub,
        :rates,
        :rates,
        ScriptedSource.sample_rates("Ruthless Covens")
      )

      assert %{
               "type" => "rates.update",
               "id" => nil,
               "payload" => %{"league" => "Ruthless Covens"}
             } =
               recv!(s.client)
    end

    test "NFR-REL-3: a failed fetch for the new league with nothing cached pushes it", ctx do
      down = %{
        Urls.poe_ninja_exchange_overview("Standard", "Currency") => {:error, :econnrefused},
        Urls.poe_ninja_stash_overview("Standard", "UniqueAccessory") => {:error, :econnrefused}
      }

      s = warm(ctx, routes: routes(down))
      request(s.client, "rates.subscribe", "c-2")
      assert %{"type" => "rates.update", "id" => "c-2"} = recv!(s.client)

      request(s.client, "league.set", "c-3", %{"league" => "Standard"})
      assert %{"type" => "league.changed", "id" => "c-3"} = recv!(s.client)
      assert_rates_error(recv!(s.client), "Standard")
      refute_frame(s.client, 200)
    end

    test "setting the same uncovered league again doesn't repeat it", ctx do
      s = warm(ctx)
      request(s.client, "rates.subscribe", "c-2")
      assert %{"type" => "rates.update"} = recv!(s.client)

      request(s.client, "league.set", "c-3", %{"league" => "Ruthless Covens"})
      assert %{"type" => "league.changed"} = recv!(s.client)
      assert_rates_error(recv!(s.client), "Ruthless Covens")

      request(s.client, "league.set", "c-4", %{"league" => "Ruthless Covens"})
      assert %{"type" => "league.changed", "id" => "c-4"} = recv!(s.client)
      refute_frame(s.client, 300)
    end

    test "not pushed without a rates subscription", ctx do
      s = warm(ctx)
      request(s.client, "league.set", "c-3", %{"league" => "Ruthless Covens"})
      assert %{"type" => "league.changed"} = recv!(s.client)
      refute_frame(s.client, 300)
    end

    test "a league the backend picks itself (fallback) is checked too", ctx do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      rates = fn _opts ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> {:ok, ScriptedSource.sample_rates()}
          _ -> {:error, :no_league}
        end
      end

      s = scripted(ctx, %{rates: rates})
      request(s.client, "rates.subscribe", "c-2")
      assert %{"type" => "rates.update", "id" => "c-2"} = recv!(s.client)

      PubSub.broadcast(s.pubsub, :league, :league_changed, "Standard")
      assert_rates_error(recv!(s.client), "Standard")
    end

    test "dropped if the league changed again before the check finished", ctx do
      test = self()
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      rates = fn _opts ->
        if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0 do
          {:ok, ScriptedSource.sample_rates()}
        else
          send(test, {:check, self()})
          receive do: (:go -> {:error, :league_not_covered})
        end
      end

      s = scripted(ctx, %{rates: rates})
      request(s.client, "rates.subscribe", "c-2")
      assert %{"type" => "rates.update", "id" => "c-2"} = recv!(s.client)

      PubSub.broadcast(s.pubsub, :league, :league_changed, "Ruthless")
      assert_receive {:check, first}, 1_000
      PubSub.broadcast(s.pubsub, :league, :league_changed, "Hardcore Ruthless")
      assert_receive {:check, second}, 1_000

      send(first, :go)
      refute_frame(s.client, 200)
      send(second, :go)
      assert_rates_error(recv!(s.client), "Hardcore Ruthless")
    end
  end

  # --- Non-blocking and failure isolation -------------------------------------------------

  describe "slow upstream" do
    test "a slow leagues.list doesn't block health pushes or other requests", ctx do
      gate = {:gate, self(), {:fixture, "trade_leagues"}}
      s = cold(ctx, routes(%{Urls.trade_leagues() => gate}), gateway: [health_interval_ms: 100])

      request(s.client, "leagues.list", "c-slow")
      assert_receive {:fixture_gate, fetcher, _url}, 1_000

      # Meanwhile: other requests are answered and health keeps flowing.
      request(s.client, "rates.unsubscribe", "c-fast")
      request(s.client, "no.such", "c-unknown")

      seen = collect(s.client, 600)
      types = Enum.map(seen, &{&1["type"], &1["id"]})
      assert {"rates.unsubscribed", "c-fast"} in types
      assert {"error", "c-unknown"} in types
      assert Enum.count(types, &match?({"health", nil}, &1)) >= 2
      refute Enum.any?(types, &match?({_, "c-slow"}, &1))

      send(fetcher, :open)
      assert %{"type" => "leagues.result", "id" => "c-slow"} = recv!(s.client)
    end

    test "a slow rates.subscribe doesn't block leagues.list", ctx do
      gate = {:gate, self(), {:fixture, "ninja_exchange_currency_covens"}}

      b =
        start_base(
          routes(%{Urls.poe_ninja_exchange_overview("Covens", "Currency") => gate}),
          ctx.tmp_dir
        )

      start_leagues(b)
      {:ok, _} = Leagues.list(b.leagues)
      start_ninja(b)
      s = connect_stack(b, [])

      request(s.client, "rates.subscribe", "c-slow")
      assert_receive {:fixture_gate, fetcher, _url}, 1_000

      request(s.client, "leagues.list", "c-fast")
      assert %{"type" => "leagues.result", "id" => "c-fast"} = recv!(s.client)

      send(fetcher, :open)
      assert %{"type" => "rates.update", "id" => "c-slow"} = recv!(s.client)
    end

    test "a crashing job answers internal and the connection stays open", ctx do
      s = scripted(ctx, %{list_leagues: fn _timeout -> raise "boom" end})
      request(s.client, "leagues.list", "c-2")
      msg = assert_error(recv!(s.client), "c-2", "internal")
      refute msg["payload"]["message"] =~ "boom"

      request(s.client, "rates.unsubscribe", "c-3")
      assert %{"type" => "rates.unsubscribed", "id" => "c-3"} = recv!(s.client)
    end

    test "jobs still running when the socket closes are stopped", ctx do
      test = self()

      s =
        scripted(ctx, %{
          list_leagues: fn _timeout ->
            send(test, {:job, self()})
            Process.sleep(:infinity)
          end
        })

      request(s.client, "leagues.list", "c-2")
      assert_receive {:job, job}, 1_000
      ref = Process.monitor(job)

      WSClient.close(s.client)
      assert_receive {:DOWN, ^ref, :process, ^job, _}, 2_000
    end
  end

  # Every frame (decoded) received within `ms`.
  defp collect(client, ms) do
    deadline = System.monotonic_time(:millisecond) + ms
    do_collect(client, deadline, [])
  end

  defp do_collect(client, deadline, acc) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:ws, ^client, {:text, text}} -> do_collect(client, deadline, [Jason.decode!(text) | acc])
    after
      left -> Enum.reverse(acc)
    end
  end
end
