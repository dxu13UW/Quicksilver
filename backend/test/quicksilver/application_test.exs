defmodule Quicksilver.ApplicationTest do
  # B1 (boots under a supervisor, serves /ws on localhost), NFR-SEC-1, NFR-REL-1.
  # Uses the application's own named processes, so it is not async.
  use ExUnit.Case, async: false

  import Quicksilver.GatewayCase, only: [hello: 1, recv_json!: 1]
  alias Quicksilver.Gateway.Endpoint
  alias Quicksilver.Test.WSClient

  @token Application.compile_env!(:quicksilver, :token)

  test "supervision tree is up with the expected children" do
    ids = Supervisor.which_children(Quicksilver.Supervisor) |> Enum.map(&elem(&1, 0))
    assert length(ids) == 5
    assert Quicksilver.Settings in ids
    assert Quicksilver.Health in ids
    assert Quicksilver.Integrations.Supervisor in ids
    assert Quicksilver.Gateway.TaskSupervisor in ids
    assert Endpoint in ids
    # stdin watcher is off in tests (config/test.exs)
    refute Quicksilver.StdinWatcher in ids
  end

  test "listener is bound to 127.0.0.1 on an OS-chosen port, and the READY line uses it" do
    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(Endpoint)
    assert port > 0

    assert Quicksilver.Launch.ready_line(Endpoint.port()) ==
             ~s(QUICKSILVER_READY {"port":#{port},"protocol_version":1})
  end

  test "the listener refuses non-loopback addresses" do
    case non_loopback_ipv4() do
      nil ->
        :ok

      ip ->
        assert {:error, _} = :gen_tcp.connect(ip, Endpoint.port(), [], 500)
    end
  end

  test "a crashing connection doesn't affect another connection" do
    b = connected_client()
    {:ok, before} = ThousandIsland.connection_pids(Endpoint)
    a = connected_client()
    {:ok, after_a} = ThousandIsland.connection_pids(Endpoint)
    [victim] = after_a -- before

    Process.exit(victim, :kill)

    assert_receive {:ws, ^a, :tcp_closed}, 1_000
    assert probe(b)
    assert Process.alive?(Process.whereis(Quicksilver.Health))
    assert Process.alive?(Process.whereis(Quicksilver.Settings))
  end

  test "Health crashing is restarted and connections keep receiving health" do
    client = connected_client()
    old = Process.whereis(Quicksilver.Health)

    ExUnit.CaptureLog.capture_log(fn ->
      Process.exit(old, :kill)
      wait_until(fn -> (new = Process.whereis(Quicksilver.Health)) && new != old end)
    end)

    assert probe(client)
    assert %{sources: [%{name: "poe_ninja", status: "idle"} | _]} = Quicksilver.Health.payload()
  end

  defp connected_client do
    {:ok, client} = WSClient.connect(Endpoint.port())
    on_exit(fn -> WSClient.close(client) end)
    WSClient.send_json(client, hello(@token))
    assert recv_json!(client)["type"] == "welcome"
    assert recv_json!(client)["type"] == "health"
    client
  end

  defp probe(client) do
    WSClient.send_json(client, %{"type" => "probe", "id" => "c-p", "payload" => %{}})

    receive do
      {:ws, ^client, {:text, text}} -> Jason.decode!(text)["payload"]["code"] == "unknown_type"
      {:ws, ^client, _closed} -> false
    after
      1_000 -> false
    end
  catch
    :exit, _ -> false
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  defp non_loopback_ipv4 do
    {:ok, addrs} = :inet.getifaddrs()

    Enum.find_value(addrs, fn {_if, opts} ->
      Enum.find_value(Keyword.get_values(opts, :addr), fn
        {127, _, _, _} -> nil
        {_, _, _, _} = ip -> ip
        _ -> nil
      end)
    end)
  end
end
