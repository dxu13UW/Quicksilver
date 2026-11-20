defmodule Quicksilver.Gateway.Handshake do
  @moduledoc """
  Validates the `hello` payload (PROTOCOL.md "Handshake"). Pure.

  Checks, in this order:

    1. `protocol_version` is an integer equal to `Quicksilver.protocol_version/0`.
       A different integer is `protocol_mismatch` (with `expected` in the
       payload); a missing or non-integer value is `bad_request`. This comes first
       so a client of another version always gets the clear "reinstall" message.
    2. `client_version` is a string, else `bad_request`.
    3. The token, when the backend has one: a missing, non-string or wrong
       `token` is `unauthorized`. Compared in constant time.

  Every failure ends the connection; the socket closes it after sending the error.
  """

  @type opts :: %{token: String.t() | nil}
  @type result ::
          {:ok, %{client_version: String.t()}}
          | {:error, :protocol_mismatch | :bad_request | :unauthorized, String.t(), map()}

  @spec check(map(), opts()) :: result()
  def check(payload, %{token: expected_token}) when is_map(payload) do
    expected_version = Quicksilver.protocol_version()

    with :ok <- check_version(payload["protocol_version"], expected_version),
         {:ok, client_version} <- check_client_version(payload["client_version"]),
         :ok <- check_token(payload["token"], expected_token) do
      {:ok, %{client_version: client_version}}
    end
  end

  defp check_version(v, v), do: :ok

  defp check_version(v, expected) when is_integer(v),
    do:
      {:error, :protocol_mismatch,
       "Backend and client versions don't match (backend speaks protocol #{expected}, client #{v}).",
       %{expected: expected}}

  defp check_version(_, _),
    do: {:error, :bad_request, "hello needs an integer \"protocol_version\".", %{}}

  defp check_client_version(v) when is_binary(v), do: {:ok, v}

  defp check_client_version(_),
    do: {:error, :bad_request, "hello needs a string \"client_version\".", %{}}

  defp check_token(_given, nil), do: :ok

  defp check_token(given, expected) when is_binary(given) do
    if Plug.Crypto.secure_compare(given, expected),
      do: :ok,
      else: unauthorized()
  end

  defp check_token(_given, _expected), do: unauthorized()

  defp unauthorized, do: {:error, :unauthorized, "The backend refused the connection token.", %{}}
end
