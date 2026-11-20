defmodule Quicksilver.Gateway.Handler do
  @moduledoc """
  Behaviour for a group of client→server message types (the routing seam).

  `Quicksilver.Gateway.Routes` maps each `type` to a module implementing this
  behaviour. The socket calls `c:handle_message/3` after the handshake for every
  well-formed request, then turns the result into frames:

    * `{:reply, type, payload, conn}`: one message, echoing the request id.
    * `{:error, code, message, conn}`: an `error` message, echoing the request id.
      `code` must be one of `Quicksilver.Gateway.Envelope.error_codes/0`.
    * `{:noreply, conn}`: nothing is sent.

  Handlers keep per-connection data (e.g. a rates subscription) in
  `conn.assigns`. An exception in a handler is caught by the socket, logged, and
  answered with error `internal`; the connection stays open.

  Payload validation is the handler's job: a missing or mistyped required
  field is `{:error, :bad_request, ...}`.
  """

  alias Quicksilver.Gateway.Connection

  @type result ::
          {:reply, String.t(), map(), Connection.t()}
          | {:error, Quicksilver.Gateway.Envelope.error_code(), String.t(), Connection.t()}
          | {:noreply, Connection.t()}

  @callback handle_message(type :: String.t(), payload :: map(), conn :: Connection.t()) ::
              result()
end
