defmodule Quicksilver.Gateway.SocketTest do
  # Verifies CON-2 (handshake), CON-3 (health push), NFR-SEC-2 (token), NFR-MNT-2
  # (PROTOCOL.md conformance of the Connection section).
  use Quicksilver.GatewayCase, async: true

  describe "handshake" do
    test "valid hello gets welcome (echoing id) then an immediate health push", ctx do
      {_client, welcome, health} = handshake!(ctx.port, ctx.token)

      assert_envelope(welcome)
      assert welcome["type"] == "welcome"
      assert welcome["id"] == "c-1"

      assert welcome["payload"] == %{
               "server_version" => Quicksilver.version(),
               "protocol_version" => 1,
               "league" => nil,
               "features" => %{"trade_api_enabled" => true},
               "health_interval_s" => 5
             }

      assert_envelope(health)
      assert health["type"] == "health"
      assert health["id"] == nil
    end

    # The case's data source reports the saved league as the active one; the
    # active-league rules themselves are covered in dashboard_test.exs.
    test "welcome carries the active league and kill-switch setting", ctx do
      :ok = Quicksilver.Settings.put(ctx.settings, "league", "Covens")
      :ok = Quicksilver.Settings.put(ctx.settings, "trade_api_enabled", false)

      {_client, welcome, _health} = handshake!(ctx.port, ctx.token)

      assert welcome["payload"]["league"] == "Covens"
      assert welcome["payload"]["features"] == %{"trade_api_enabled" => false}
    end

    test "wrong token gets unauthorized, then the connection closes", ctx do
      client = connect!(ctx.port)
      WSClient.send_json(client, hello("not-the-token"))

      msg = recv_json!(client) |> assert_envelope()
      assert msg["type"] == "error"
      assert msg["id"] == "c-1"
      assert msg["payload"]["code"] == "unauthorized"
      assert is_binary(msg["payload"]["message"])
      assert assert_closed!(client) == 1008
    end

    test "missing token gets unauthorized", ctx do
      client = connect!(ctx.port)
      WSClient.send_json(client, update_in(hello(ctx.token)["payload"], &Map.delete(&1, "token")))

      assert recv_json!(client)["payload"]["code"] == "unauthorized"
      assert assert_closed!(client) == 1008
    end

    @tag gateway: [token: nil]
    test "with no token configured (dev), any token is accepted", ctx do
      client = connect!(ctx.port)
      WSClient.send_json(client, update_in(hello("x")["payload"], &Map.delete(&1, "token")))

      assert recv_json!(client)["type"] == "welcome"
    end

    test "different protocol_version gets protocol_mismatch with expected, then close", ctx do
      client = connect!(ctx.port)
      WSClient.send_json(client, hello(ctx.token, %{"protocol_version" => 2}))

      msg = recv_json!(client)
      assert msg["type"] == "error"
      assert msg["id"] == "c-1"
      assert msg["payload"]["code"] == "protocol_mismatch"
      assert msg["payload"]["expected"] == 1
      assert assert_closed!(client) == 1008
    end

    test "protocol_mismatch wins over a wrong token", ctx do
      client = connect!(ctx.port)
      WSClient.send_json(client, hello("wrong", %{"protocol_version" => 7}))

      assert recv_json!(client)["payload"]["code"] == "protocol_mismatch"
    end

    test "hello with a non-integer protocol_version gets bad_request, then close", ctx do
      client = connect!(ctx.port)
      WSClient.send_json(client, hello(ctx.token, %{"protocol_version" => "1"}))

      assert recv_json!(client)["payload"]["code"] == "bad_request"
      assert assert_closed!(client) == 1008
    end

    test "a message before hello gets unauthorized (echoing its id), then close", ctx do
      client = connect!(ctx.port)
      WSClient.send_json(client, %{"type" => "leagues.list", "id" => "c-9", "payload" => %{}})

      msg = recv_json!(client)
      assert msg["id"] == "c-9"
      assert msg["payload"]["code"] == "unauthorized"
      assert assert_closed!(client) == 1008
    end

    test "invalid JSON before hello gets unauthorized, then close", ctx do
      client = connect!(ctx.port)
      WSClient.send_text(client, "{nope")

      msg = recv_json!(client)
      assert msg["id"] == nil
      assert msg["payload"]["code"] == "unauthorized"
      assert assert_closed!(client) == 1008
    end

    @tag gateway: [hello_timeout_ms: 100]
    test "no hello within the timeout gets unauthorized, then close", ctx do
      client = connect!(ctx.port)

      msg = recv_json!(client, 1_000)
      assert msg["type"] == "error"
      assert msg["id"] == nil
      assert msg["payload"]["code"] == "unauthorized"
      assert assert_closed!(client) == 1008
    end

    @tag gateway: [hello_timeout_ms: 100]
    test "the hello timeout does not fire after a successful handshake", ctx do
      {client, _welcome, _health} = handshake!(ctx.port, ctx.token)
      refute_frame(client, 300)
    end
  end

  describe "after the handshake" do
    setup ctx do
      {client, _welcome, _health} = handshake!(ctx.port, ctx.token)
      %{client: client}
    end

    test "invalid JSON gets bad_json and the connection stays open", ctx do
      WSClient.send_text(ctx.client, "{not json")
      msg = recv_json!(ctx.client) |> assert_envelope()
      assert msg["type"] == "error"
      assert msg["id"] == nil
      assert msg["payload"]["code"] == "bad_json"

      assert_still_open(ctx.client)
    end

    test "valid JSON that isn't an envelope gets bad_json", ctx do
      for frame <- [
            ~s([1,2]),
            ~s({"payload":{}}),
            ~s({"type":"x"}),
            ~s({"type":"x","payload":[]}),
            ~s({"type":5,"payload":{}}),
            ~s({"type":"x","id":7,"payload":{}})
          ] do
        WSClient.send_text(ctx.client, frame)
        assert recv_json!(ctx.client)["payload"]["code"] == "bad_json", frame
      end

      assert_still_open(ctx.client)
    end

    test "bad_json echoes the id when it can be read", ctx do
      WSClient.send_text(ctx.client, ~s({"type":"x","id":"c-3"}))
      msg = recv_json!(ctx.client)
      assert msg["id"] == "c-3"
      assert msg["payload"]["code"] == "bad_json"
    end

    test "a binary frame gets bad_json", ctx do
      WSClient.send_binary(ctx.client, <<1, 2, 3>>)
      assert recv_json!(ctx.client)["payload"]["code"] == "bad_json"
      assert_still_open(ctx.client)
    end

    test "unknown type gets unknown_type, echoing the id, and the connection stays open", ctx do
      WSClient.send_json(ctx.client, %{"type" => "no.such", "id" => "c-2", "payload" => %{}})

      msg = recv_json!(ctx.client) |> assert_envelope()
      assert msg["type"] == "error"
      assert msg["id"] == "c-2"
      assert msg["payload"]["code"] == "unknown_type"

      assert_still_open(ctx.client)
    end

    # Phase C: the Dashboard types are routed (full coverage in dashboard_test.exs).
    # These two don't need a data source to answer.
    test "dashboard types are routed, not unknown_type", ctx do
      assert Enum.sort(Quicksilver.Gateway.Routes.types()) ==
               ~w(league.set leagues.list rates.subscribe rates.unsubscribe)

      WSClient.send_json(ctx.client, %{"type" => "league.set", "id" => "c-7", "payload" => %{}})
      assert %{"id" => "c-7", "payload" => %{"code" => "bad_request"}} = recv_json!(ctx.client)

      WSClient.send_json(ctx.client, %{
        "type" => "rates.unsubscribe",
        "id" => "c-8",
        "payload" => %{}
      })

      assert %{"type" => "rates.unsubscribed", "id" => "c-8"} = recv_json!(ctx.client)
    end

    test "unknown envelope fields are ignored", ctx do
      WSClient.send_json(ctx.client, %{
        "type" => "no.such",
        "id" => "c-5",
        "payload" => %{},
        "extra" => 1
      })

      assert recv_json!(ctx.client)["payload"]["code"] == "unknown_type"
    end

    test "a second hello gets bad_request and the connection stays open", ctx do
      WSClient.send_json(ctx.client, hello(ctx.token))
      msg = recv_json!(ctx.client)
      assert msg["payload"]["code"] == "bad_request"
      assert_still_open(ctx.client)
    end
  end

  describe "health push" do
    @tag gateway: [health_interval_ms: 100]
    test "repeats every interval in the PROTOCOL shape", ctx do
      {client, welcome, first} = handshake!(ctx.port, ctx.token)
      assert welcome["payload"]["health_interval_s"] == 0.1

      second = recv_json!(client, 1_000) |> assert_envelope()
      third = recv_json!(client, 1_000)

      for msg <- [first, second, third] do
        assert msg["type"] == "health"
        assert msg["id"] == nil
        assert_health_payload(msg["payload"])
      end
    end

    test "lists the Week 2 sources as idle at startup, in order", ctx do
      {_client, _welcome, health} = handshake!(ctx.port, ctx.token)

      assert [
               %{
                 "name" => "poe_ninja",
                 "status" => "idle",
                 "last_success" => nil,
                 "cache_age_s" => nil,
                 "detail" => nil,
                 "rate_limit" => nil
               },
               %{
                 "name" => "trade_leagues",
                 "status" => "idle",
                 "last_success" => nil,
                 "cache_age_s" => nil,
                 "detail" => nil,
                 "rate_limit" => nil
               }
             ] = health["payload"]["sources"]
    end

    @tag gateway: [health_interval_ms: 100]
    test "reflects reports from data sources", ctx do
      fetched = DateTime.add(DateTime.utc_now(), -245, :second)

      Quicksilver.Health.report(ctx.health, :poe_ninja, status: :ok, cached_at: fetched)

      Quicksilver.Health.report(ctx.health, :trade_api,
        rate_limit: %{policy: "trade-search-request-limit", queued: 0, restricted_until: nil}
      )

      {_client, _welcome, health} = handshake!(ctx.port, ctx.token)
      [ninja, leagues, trade] = health["payload"]["sources"]

      assert ninja["status"] == "ok"
      assert ninja["last_success"] =~ ts_regex()
      assert ninja["cache_age_s"] in 245..246
      assert leagues["name"] == "trade_leagues"

      assert trade == %{
               "name" => "trade_api",
               "status" => "idle",
               "last_success" => nil,
               "cache_age_s" => nil,
               "detail" => nil,
               "rate_limit" => %{
                 "policy" => "trade-search-request-limit",
                 "queued" => 0,
                 "restricted_until" => nil
               }
             }
    end
  end

  describe "HTTP" do
    test "other paths are 404 and a plain GET /ws is 400", ctx do
      {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", ctx.port, mode: :passive)
      assert {404, conn} = get_status(conn, "/")
      assert {400, _conn} = get_status(conn, "/ws")
    end
  end

  defp get_status(conn, path) do
    {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", path, [], nil)
    {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, 1_000)
    {:status, ^ref, status} = List.keyfind(responses, :status, 0)

    {:ok, conn, _} =
      if({:done, ref} in responses, do: {:ok, conn, []}, else: Mint.HTTP.recv(conn, 0, 1_000))

    {status, conn}
  end

  defp assert_still_open(client) do
    WSClient.send_json(client, %{"type" => "still.open", "id" => "c-probe", "payload" => %{}})
    msg = recv_json!(client)
    assert msg["id"] == "c-probe"
    assert msg["payload"]["code"] == "unknown_type"
  end

  defp assert_health_payload(payload) do
    assert %{"uptime_s" => uptime, "sources" => sources} = payload
    assert is_integer(uptime) and uptime >= 0
    assert is_list(sources) and sources != []

    for source <- sources do
      assert Map.keys(source) |> Enum.sort() ==
               ~w(cache_age_s detail last_success name rate_limit status)

      assert source["status"] in ~w(idle ok degraded down)
    end
  end
end
