defmodule Quicksilver.Gateway.Envelope do
  @moduledoc """
  The message envelope from PROTOCOL.md "Envelope":

      {"type": "rates.update", "id": "c-12", "ts": "2026-11-19T21:04:05.123Z", "payload": {}}

  Pure functions; no process state.

  Decoding rules:
    * The frame must be a JSON object with a string `type` and an object
      `payload`; otherwise it's `bad_json`.
    * `id` must be a string or `null` (absent is treated as `null`). Any other
      `id` is also reported as `bad_json`, since it is an envelope fault, not a
      payload fault.
    * `ts` from the client is not validated or used.
    * Unknown top-level fields are ignored.
  """

  @error_codes ~w(bad_json bad_request unknown_type unauthorized protocol_mismatch
                  unknown_league upstream_unavailable internal)a

  @type id :: String.t() | nil
  @type t :: %{type: String.t(), id: id(), payload: map()}
  @type error_code ::
          :bad_json
          | :bad_request
          | :unknown_type
          | :unauthorized
          | :protocol_mismatch
          | :unknown_league
          | :upstream_unavailable
          | :internal

  @doc "All error codes from the PROTOCOL table."
  @spec error_codes() :: [error_code()]
  def error_codes, do: @error_codes

  @doc """
  Decodes one text frame.

  On failure returns `{:error, message, id}` where `id` is the frame's `id` if it
  could be read (so the `bad_json` reply can still echo it), else `nil`.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, String.t(), id()}
  def decode(frame) when is_binary(frame) do
    case Jason.decode(frame) do
      {:ok, %{} = object} -> from_object(object)
      {:ok, _other} -> {:error, "A message must be a JSON object.", nil}
      {:error, _} -> {:error, "The message isn't valid JSON.", nil}
    end
  end

  defp from_object(object) do
    raw_id = Map.get(object, "id")
    echo_id = if is_binary(raw_id), do: raw_id, else: nil

    case object do
      %{"type" => type, "payload" => %{} = payload}
      when is_binary(type) and type != "" and (is_binary(raw_id) or is_nil(raw_id)) ->
        {:ok, %{type: type, id: raw_id, payload: payload}}

      %{"type" => type} when not is_binary(type) or type == "" ->
        {:error, "The message needs a non-empty string \"type\".", echo_id}

      %{"type" => _, "payload" => %{}} ->
        {:error, "\"id\" must be a string or null.", nil}

      %{"type" => _} ->
        {:error, "The message needs an object \"payload\".", echo_id}

      _ ->
        {:error, "The message needs a \"type\" and a \"payload\".", echo_id}
    end
  end

  @doc "Encodes a message with `ts` set to now."
  @spec encode(String.t(), id(), map()) :: String.t()
  def encode(type, id, payload) when is_binary(type) and is_map(payload) do
    Jason.encode!(%{type: type, id: id, ts: Quicksilver.Time.now_iso(), payload: payload})
  end

  @doc """
  Encodes an `error` message. `extra` is merged into the payload, e.g.
  `%{expected: 1}` for `protocol_mismatch`.
  """
  @spec error(error_code(), String.t(), id(), map()) :: String.t()
  def error(code, message, id, extra \\ %{}) when code in @error_codes and is_binary(message) do
    encode("error", id, Map.merge(extra, %{code: Atom.to_string(code), message: message}))
  end
end
