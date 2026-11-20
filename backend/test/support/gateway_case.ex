defmodule Quicksilver.GatewayCase do
  @moduledoc """
  Starts an isolated gateway per test: its own Settings (in the test's tmp dir),
  Health, and Endpoint on an OS-chosen port, all with unique names, so tests can
  run async and never touch the application's own instances.

  Tag a test with `@tag gateway: [token: nil, hello_timeout_ms: 100, ...]` to
  override endpoint options.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias Quicksilver.Test.WSClient

  @token "s3cret-test-token-0123456789abcd"

  using do
    quote do
      import Quicksilver.GatewayCase
      alias Quicksilver.Test.WSClient
      @moduletag :tmp_dir
    end
  end

  setup context do
    uniq = System.unique_integer([:positive])
    settings = :"settings_#{uniq}"
    health = :"health_#{uniq}"
    endpoint = :"endpoint_#{uniq}"

    start_supervised!({Quicksilver.Settings, name: settings, dir: context.tmp_dir}, id: settings)
    start_supervised!({Quicksilver.Health, name: health}, id: health)

    overrides = Map.get(context, :gateway, [])

    endpoint_opts =
      Keyword.merge(
        [
          name: endpoint,
          port: 0,
          token: @token,
          hello_timeout_ms: 5_000,
          health_interval_ms: 5_000,
          health: health,
          settings: settings
        ],
        overrides
      )

    start_supervised!({Quicksilver.Gateway.Endpoint, endpoint_opts})

    %{
      port: Quicksilver.Gateway.Endpoint.port(endpoint),
      token: endpoint_opts[:token],
      health: health,
      settings: settings,
      endpoint: endpoint
    }
  end

  @doc "Default token used by the case."
  def token, do: @token

  @doc "Opens a client; it is closed when the test ends."
  def connect!(port) do
    {:ok, client} = WSClient.connect(port)
    ExUnit.Callbacks.on_exit(fn -> WSClient.close(client) end)
    client
  end

  @doc "A valid hello envelope with optional payload overrides."
  def hello(token, overrides \\ %{}) do
    %{
      "type" => "hello",
      "id" => "c-1",
      "ts" => "2026-11-19T21:04:05.123Z",
      "payload" =>
        Map.merge(
          %{"client_version" => "0.1.0", "protocol_version" => 1, "token" => token},
          overrides
        )
    }
  end

  @doc "Connects and completes the handshake; returns `{client, welcome, first_health}`."
  def handshake!(port, token) do
    client = connect!(port)
    :ok = WSClient.send_json(client, hello(token))
    welcome = recv_json!(client)
    health = recv_json!(client)
    {client, welcome, health}
  end

  @doc "Waits for the next text frame and decodes it."
  def recv_json!(client, timeout \\ 1_000) do
    receive do
      {:ws, ^client, {:text, text}} -> Jason.decode!(text)
      {:ws, ^client, other} -> flunk("expected a text frame, got #{inspect(other)}")
    after
      timeout -> flunk("no frame within #{timeout} ms")
    end
  end

  @doc "Asserts the server closes the connection; returns the close code."
  def assert_closed!(client, timeout \\ 1_000) do
    receive do
      {:ws, ^client, {:close, code, _reason}} -> code
      {:ws, ^client, :tcp_closed} -> :tcp_closed
      {:ws, ^client, other} -> flunk("expected close, got #{inspect(other)}")
    after
      timeout -> flunk("connection not closed within #{timeout} ms")
    end
  end

  @doc "Asserts nothing arrives on `client` for `ms` milliseconds."
  def refute_frame(client, ms \\ 100) do
    receive do
      {:ws, ^client, frame} -> flunk("unexpected frame #{inspect(frame)}")
    after
      ms -> :ok
    end
  end

  @ts_regex ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/
  @doc "Regex for a wire timestamp."
  def ts_regex, do: @ts_regex

  @doc "Asserts the common envelope shape and returns the message."
  def assert_envelope(%{"type" => type, "ts" => ts, "payload" => payload} = msg)
      when is_binary(type) and is_map(payload) do
    assert Map.has_key?(msg, "id")
    assert ts =~ @ts_regex
    msg
  end
end
