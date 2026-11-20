defmodule Quicksilver.Gateway.HTTP do
  @moduledoc """
  The HTTP entry point. Only `GET /ws` exists: it upgrades to a WebSocket
  handled by `Quicksilver.Gateway.Socket`. Everything else is 404.

  On `GET /ws`, in this order:

    1. A request that carries an `Origin` header (any value, including `null`
       or an empty one) is refused with 403 before the upgrade (PROTOCOL.md
       "Origin check"). Browsers always send `Origin` and the Qt client sends
       none, so this keeps web pages in the user's browser from reaching the
       backend, even in dev mode where there's no token.
    2. A request that isn't a valid WebSocket upgrade is 400.
    3. Otherwise the connection is upgraded.
  """

  @behaviour Plug

  import Plug.Conn
  require Logger

  @impl Plug
  def init(gateway_opts), do: gateway_opts

  @impl Plug
  def call(%Plug.Conn{method: "GET", path_info: ["ws"]} = conn, gateway_opts) do
    case get_req_header(conn, "origin") do
      [] ->
        upgrade(conn, gateway_opts)

      origins ->
        Logger.info("gateway: rejected /ws request with Origin #{inspect(origins)}")
        conn |> send_resp(403, "Forbidden") |> halt()
    end
  end

  def call(conn, _opts), do: conn |> send_resp(404, "Not found") |> halt()

  defp upgrade(conn, gateway_opts) do
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
end
