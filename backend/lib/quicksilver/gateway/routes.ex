defmodule Quicksilver.Gateway.Routes do
  @moduledoc """
  Maps client→server message `type`s to their `Quicksilver.Gateway.Handler`.

  `hello` is not listed: the handshake is handled by the socket itself, before
  any routing happens. A type that isn't in this table gets error
  `unknown_type` and the connection stays open (PROTOCOL.md "Envelope").

  To add a message group: write a handler module under
  `Quicksilver.Gateway.Handlers` and add its types here.
  """

  @routes %{
            # TODO(Phase C, after integrations I1/I2 land): route the Dashboard section of
            # PROTOCOL.md to a Quicksilver.Gateway.Handlers.Dashboard module:
            #   "leagues.list"      => Quicksilver.Gateway.Handlers.Dashboard,
            #   "league.set"        => Quicksilver.Gateway.Handlers.Dashboard,
            #   "rates.subscribe"   => Quicksilver.Gateway.Handlers.Dashboard,
            #   "rates.unsubscribe" => Quicksilver.Gateway.Handlers.Dashboard,
            # Until then these types answer `unknown_type`, as the session brief requires.
            # rates.update pushes will also need the socket to accept a push message
            # from the rates cache (see the TODO in Quicksilver.Gateway.Socket).
          }

  @doc "The handler module for `type`, or `:error` if the type is unknown."
  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(type), do: Map.fetch(@routes, type)

  @doc "All routed types (for tests and diagnostics)."
  @spec types() :: [String.t()]
  def types, do: Map.keys(@routes)
end
