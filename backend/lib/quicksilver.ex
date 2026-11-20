defmodule Quicksilver do
  @moduledoc """
  Quicksilver backend: a local service for the Quicksilver Path of Exile companion.

  The C++/Qt client starts this service and talks to it over one WebSocket on
  `127.0.0.1` (docs/PROTOCOL.md, ADR-002). Entry points:

    * `Quicksilver.Application`: supervision tree and launch sequence.
    * `Quicksilver.Gateway.Socket`: the `/ws` connection (envelope, handshake, routing).
    * `Quicksilver.Health`: per-source status, pushed to the client as `health`.
    * `Quicksilver.Settings`: `settings.json` in the user config directory.
  """

  @protocol_version 1

  @doc "The `protocol_version` this backend speaks (docs/PROTOCOL.md)."
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @doc "The backend's own version, sent as `server_version` in `welcome`."
  @spec version() :: String.t()
  def version do
    case Application.spec(:quicksilver, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end
end
