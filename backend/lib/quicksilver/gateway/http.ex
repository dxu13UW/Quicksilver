defmodule Quicksilver.Gateway.HTTP do
  @moduledoc """
  The HTTP entry point. Only `GET /ws` exists: it upgrades to a WebSocket
  handled by `Quicksilver.Gateway.Socket`. Everything else is 404, and a
  `GET /ws` that isn't a valid upgrade request is 400.
  """

  @behaviour Plug

  import Plug.Conn
  require Logger

  @impl Plug
  def init(gateway_opts), do: gateway_opts

  @impl Plug
  def call(%Plug.Conn{method: "GET", path_info: ["ws"]} = conn, gateway_opts) do
    conn
    |> WebSockAdapter.upgrade(Quicksilver.Gateway.Socket, gateway_opts,
      # No idle timeout: the client may stay silent for hours while the server
      # pushes health. A dead client is detected by the TCP close (loopback only).
      timeout: :infinity,
      max_frame_size: gateway_opts.max_frame_size,
      compress: false,
      validate_utf8: true
    )
    |> halt()
  rescue
    e in WebSockAdapter.UpgradeError ->
      Logger.info("gateway: rejected non-WebSocket request to /ws: #{Exception.message(e)}")
      conn |> send_resp(400, "WebSocket upgrade required") |> halt()
  end

  def call(conn, _opts), do: conn |> send_resp(404, "Not found") |> halt()
end
