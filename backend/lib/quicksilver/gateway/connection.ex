defmodule Quicksilver.Gateway.Connection do
  @moduledoc """
  Per-connection state held by `Quicksilver.Gateway.Socket` and passed to handlers.

    * `phase`: `:awaiting_hello` until a valid `hello`, then `:ready`.
    * `opts`: the gateway options (`Quicksilver.Gateway.Endpoint.gateway_opts/1`).
    * `client_version`: from `hello`, once ready.
    * `assigns`: free-form map for handlers (subscriptions and the like).
    * `hello_timer` / `health_timer`: timer refs owned by the socket.
  """

  @enforce_keys [:opts]
  defstruct phase: :awaiting_hello,
            opts: nil,
            client_version: nil,
            assigns: %{},
            hello_timer: nil,
            health_timer: nil

  @type t :: %__MODULE__{
          phase: :awaiting_hello | :ready,
          opts: map(),
          client_version: String.t() | nil,
          assigns: map(),
          hello_timer: reference() | nil,
          health_timer: reference() | nil
        }
end
