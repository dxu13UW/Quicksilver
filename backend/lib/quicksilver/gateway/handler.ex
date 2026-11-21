defmodule Quicksilver.Gateway.Handler do
  @moduledoc """
  Behaviour for a group of client→server message types (the routing seam).

  `Quicksilver.Gateway.Routes` maps each `type` to a module implementing this
  behaviour. The socket calls `c:handle_message/3` after the handshake for every
  well-formed request, then turns the result into frames:

    * `{:reply, type, payload, conn}`: one message, echoing the request id.
    * `{:error, code, message, conn}`: an `error` message, echoing the request id.
      `code` must be one of `Quicksilver.Gateway.Envelope.error_codes/0`.
    * `{:frames, frames, conn}`: several messages in order. Each frame is
      `{:reply, type, payload}` or `{:error, code, message}` (both echo the
      request id), or a push with id `null`: `{:push, type, payload}` or
      `{:push_error, code, message, extra}` (`extra` is merged into the error
      payload, e.g. PROTOCOL's rates error push).
    * `{:noreply, conn}`: nothing is sent.
    * `{:async, fun, conn}`: `fun` (arity 0) runs in a task under the gateway's
      task supervisor, so a slow data source never blocks the connection
      process: health pushes and other requests keep flowing meanwhile. When it
      finishes, the socket calls `c:handle_async/3` with `{:ok, value}`, or
      `{:exit, reason}` if the task crashed, and sends that result as above
      (still echoing the original request id). Replies to concurrent requests
      may therefore arrive out of request order; clients match them by id.

  Handlers keep per-connection data (e.g. a rates subscription) in
  `conn.assigns`. An exception or exit in a handler is caught by the socket,
  logged, and answered with error `internal`; the connection stays open.

  Payload validation is the handler's job: a missing or mistyped required
  field is `{:error, :bad_request, ...}`.

  Process messages the socket doesn't handle itself (e.g. data-source
  broadcasts) are given to `c:handle_info/2` of the handler that
  `Quicksilver.Gateway.Routes.info_handler/1` names; it returns
  `{:push, [{type, payload}], conn}` (pushes, id `null`), `{:ok, conn}`, or
  `{:async, job_type, fun, conn}`: a job like `{:async, ...}` above that isn't
  tied to a request; `c:handle_async/3` gets `job_type`, and anything it sends
  has id `null`.
  """

  alias Quicksilver.Gateway.Connection

  @type frame ::
          {:reply, String.t(), map()}
          | {:error, Quicksilver.Gateway.Envelope.error_code(), String.t()}
          | {:push_error, Quicksilver.Gateway.Envelope.error_code(), String.t(), map()}
          | {:push, String.t(), map()}

  @type result ::
          {:reply, String.t(), map(), Connection.t()}
          | {:error, Quicksilver.Gateway.Envelope.error_code(), String.t(), Connection.t()}
          | {:frames, [frame()], Connection.t()}
          | {:noreply, Connection.t()}

  @callback handle_message(type :: String.t(), payload :: map(), conn :: Connection.t()) ::
              result() | {:async, (-> term()), Connection.t()}

  @callback handle_async(
              type :: String.t(),
              outcome :: {:ok, term()} | {:exit, term()},
              conn :: Connection.t()
            ) :: result()

  @callback handle_info(message :: term(), conn :: Connection.t()) ::
              {:push, [{String.t(), map()}], Connection.t()}
              | {:ok, Connection.t()}
              | {:async, String.t(), (-> term()), Connection.t()}

  @optional_callbacks handle_async: 3, handle_info: 2
end
