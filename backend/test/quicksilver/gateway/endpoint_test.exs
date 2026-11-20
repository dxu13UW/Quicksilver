defmodule Quicksilver.Gateway.EndpointTest do
  # CON-4 / NFR-REL-1: a restarted listener keeps the port announced in READY.
  use Quicksilver.GatewayCase, async: true

  test "a crashed listener is restarted on the same port", ctx do
    old = Process.whereis(ctx.endpoint)
    port = ctx.port

    ExUnit.CaptureLog.capture_log(fn ->
      Process.exit(old, :kill)
      wait_for_new_pid(ctx.endpoint, old)
    end)

    assert Quicksilver.Gateway.Endpoint.port(ctx.endpoint) == port
    {_client, welcome, _health} = handshake!(port, ctx.token)
    assert welcome["type"] == "welcome"
  end

  test "gateway options default to the PROTOCOL values" do
    opts = Quicksilver.Gateway.Endpoint.gateway_opts([])
    assert opts.hello_timeout_ms == 5_000
    assert opts.health_interval_ms == 5_000
    assert opts.token == nil
  end

  defp wait_for_new_pid(name, old, tries \\ 100) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old ->
        :ok

      _ when tries > 0 ->
        Process.sleep(10)
        wait_for_new_pid(name, old, tries - 1)

      _ ->
        flunk("listener was not restarted")
    end
  end
end
