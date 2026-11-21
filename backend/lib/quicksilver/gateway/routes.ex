defmodule Quicksilver.Gateway.Routes do
  @moduledoc """
  Maps client→server message `type`s to their `Quicksilver.Gateway.Handler`.

  `hello` is not listed: the handshake is handled by the socket itself, before
  any routing happens. A type that isn't in this table gets error
  `unknown_type` and the connection stays open (PROTOCOL.md "Envelope").

  To add a message group: write a handler module under
  `Quicksilver.Gateway.Handlers` and add its types here. If it needs process
  messages (e.g. data-source broadcasts), add a clause to `info_handler/1`.
  """

  alias Quicksilver.Gateway.Handlers.Dashboard

  @routes %{
    # PROTOCOL.md "Dashboard"
    "leagues.list" => Dashboard,
    "league.set" => Dashboard,
    "rates.subscribe" => Dashboard,
    "rates.unsubscribe" => Dashboard
  }

  @doc "The handler module for `type`, or `:error` if the type is unknown."
  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(type), do: Map.fetch(@routes, type)

  @doc "All routed types (for tests and diagnostics)."
  @spec types() :: [String.t()]
  def types, do: Map.keys(@routes)

  @doc """
  The handler that receives a process message sent to a connection, or
  `:error` if no handler wants it (it is then dropped).
  """
  @spec info_handler(term()) :: {:ok, module()} | :error
  def info_handler({Quicksilver.Integrations, _event, _payload}), do: {:ok, Dashboard}
  def info_handler(_message), do: :error
end
