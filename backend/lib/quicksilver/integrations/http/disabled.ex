defmodule Quicksilver.Integrations.HTTP.Disabled do
  @moduledoc """
  Transport that refuses every request with `{:error, :http_disabled}`.

  Default in the test env (so `mix test` can never reach the network) and when
  `QUICKSILVER_OFFLINE=1` is set. See `Quicksilver.Integrations.Config`.
  """

  @behaviour Quicksilver.Integrations.HTTP

  @impl true
  def request(_method, _url, _headers, _body, _opts), do: {:error, :http_disabled}
end
