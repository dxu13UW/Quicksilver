defmodule Quicksilver.Gateway.OriginTest do
  # PROTOCOL.md "Handshake rules in detail" → Origin check: an upgrade request
  # that carries an `Origin` header is refused with HTTP 403. (No REQUIREMENTS.md
  # ID covers this directly; it backs NFR-SEC-1/NFR-SEC-2 against browser pages.)
  use Quicksilver.GatewayCase, async: true

  import ExUnit.CaptureLog

  test "an upgrade with Origin: http://example.com gets 403 and no WebSocket", ctx do
    capture_log(fn ->
      assert {403, headers, _body} = raw_upgrade(ctx.port, [{"origin", "http://example.com"}])
      refute has_upgrade_headers?(headers)
    end)
  end

  test "an upgrade with Origin: null gets 403 and no WebSocket", ctx do
    capture_log(fn ->
      assert {403, headers, _body} = raw_upgrade(ctx.port, [{"origin", "null"}])
      refute has_upgrade_headers?(headers)
    end)
  end

  test "a refused upgrade never reaches the socket: no frames, no handshake", ctx do
    capture_log(fn ->
      assert {:error, %Mint.WebSocket.UpgradeFailureError{status_code: 403}} =
               WSClient.connect(ctx.port, "/ws", [{"origin", "http://example.com"}])
    end)
  end

  # TP-HS-017: an empty value counts too.
  test "an upgrade with an empty Origin value gets 403 and no WebSocket", ctx do
    capture_log(fn ->
      assert {403, headers, _body} = raw_upgrade(ctx.port, [{"origin", ""}])
      refute has_upgrade_headers?(headers)
    end)
  end

  # TP-HS-018: the check runs before upgrade validation.
  test "a plain GET /ws (no upgrade) with Origin gets 403 Forbidden, not 400", ctx do
    capture_log(fn ->
      assert {403, "Forbidden"} = plain_get(ctx.port, [{"origin", "http://example.com"}])
    end)

    # Without Origin the same request is a 400 (not an upgrade).
    capture_log(fn -> assert {400, _} = plain_get(ctx.port, []) end)
  end

  @tag gateway: [token: nil]
  test "Origin is refused even in dev mode (no token)", ctx do
    capture_log(fn ->
      assert {403, _headers, _body} = raw_upgrade(ctx.port, [{"origin", "http://example.com"}])
    end)
  end

  test "an upgrade without an Origin header upgrades normally", ctx do
    assert {101, headers, _body} = raw_upgrade(ctx.port, [])
    assert has_upgrade_headers?(headers)

    {_client, welcome, health} = handshake!(ctx.port, ctx.token)
    assert welcome["type"] == "welcome"
    assert health["type"] == "health"
  end

  # A plain HTTP GET /ws; returns {status, body}.
  defp plain_get(port, headers) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, mode: :passive)
    {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", "/ws", headers, nil)
    result = recv_response(conn, ref, {nil, ""})
    Mint.HTTP.close(conn)
    result
  end

  defp recv_response(conn, ref, {status, body}) do
    {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, 2_000)

    {acc, done?} =
      Enum.reduce(responses, {{status, body}, false}, fn
        {:status, ^ref, s}, {{_, b}, d} -> {{s, b}, d}
        {:data, ^ref, data}, {{s, b}, d} -> {{s, b <> data}, d}
        {:done, ^ref}, {a, _} -> {a, true}
        _, a -> a
      end)

    if done?, do: acc, else: recv_response(conn, ref, acc)
  end

  # Sends a WebSocket upgrade request with `extra_headers` and returns the
  # server's `{status, headers, body}` without completing the WebSocket setup.
  defp raw_upgrade(port, extra_headers) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/ws", extra_headers)
    result = collect(conn, ref, {nil, [], ""})
    {:ok, _} = Mint.HTTP.close(conn)
    result
  end

  defp collect(conn, ref, {status, headers, body} = acc) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            {acc, done?} =
              Enum.reduce(responses, {acc, false}, fn
                {:status, ^ref, s}, {{_, h, b}, d} -> {{s, h, b}, d}
                {:headers, ^ref, h}, {{s, _, b}, d} -> {{s, h, b}, d}
                {:data, ^ref, data}, {{s, h, b}, d} -> {{s, h, b <> data}, d}
                {:done, ^ref}, {a, _} -> {a, true}
                _, a -> a
              end)

            if done?, do: acc, else: collect(conn, ref, acc)

          {:error, _conn, reason, _responses} ->
            flunk("upgrade request failed: #{inspect(reason)}")

          :unknown ->
            collect(conn, ref, acc)
        end
    after
      2_000 -> flunk("no response (so far: #{inspect({status, headers, body})})")
    end
  end

  defp has_upgrade_headers?(headers) do
    Enum.any?(headers, fn {name, value} ->
      String.downcase(name) == "upgrade" and String.downcase(value) == "websocket"
    end)
  end
end
