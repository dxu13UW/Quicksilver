defmodule Quicksilver.Integrations.HTTP do
  @moduledoc """
  The only way the backend makes an external HTTP request (CLAUDE.md rule 3).

  `get_json/2`:

    1. waits for a slot from `Quicksilver.Integrations.RateLimiter` (requests
       queue, they are never dropped),
    2. sends the project User-Agent (`user_agent/0`, DATA_SOURCES.md), plus
       `accept: application/json` and `accept-encoding: gzip`,
    3. hands the response status and headers back to the limiter so it can learn
       the `x-rate-limit-*` policy,
    4. un-gzips and decodes the JSON body.

  The transport is an **adapter** module implementing this behaviour:

    * `Quicksilver.Integrations.HTTP.MintAdapter`: real requests (TLS with
      `verify: :verify_peer` and OTP's `:public_key.cacerts_get/0`).
    * `Quicksilver.Integrations.HTTP.Disabled`: refuses every request. Default
      in the test env and with `QUICKSILVER_OFFLINE=1`.
    * Tests use a fixture adapter that replays recorded responses.

  An adapter is given as `module` or `{module, adapter_opts}`.
  """

  alias Quicksilver.Integrations.RateLimiter

  @contact "https://github.com/dxu13UW/Quicksilver"

  defmodule Response do
    @moduledoc "A complete HTTP response. Header names are lowercase."
    defstruct status: nil, headers: [], body: ""

    @type t :: %__MODULE__{
            status: non_neg_integer(),
            headers: [{String.t(), String.t()}],
            body: binary()
          }

    @doc "First value of header `name` (case-insensitive), or nil."
    @spec header(t() | [{String.t(), String.t()}], String.t()) :: String.t() | nil
    def header(%__MODULE__{headers: headers}, name), do: header(headers, name)

    def header(headers, name) when is_list(headers) do
      name = String.downcase(name)

      Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
    end
  end

  @type headers :: [{String.t(), String.t()}]
  @type adapter :: module() | {module(), keyword()}
  @type error ::
          {:http_status, non_neg_integer()}
          | {:transport, term()}
          | {:decode, term()}
          | :http_disabled

  @callback request(
              method :: String.t(),
              url :: String.t(),
              headers(),
              body :: iodata() | nil,
              opts :: keyword()
            ) :: {:ok, Response.t()} | {:error, term()}

  @doc "The User-Agent sent on every request (DATA_SOURCES.md \"User-Agent\")."
  @spec user_agent() :: String.t()
  def user_agent, do: "Quicksilver/#{Quicksilver.version()} (contact: #{@contact})"

  @doc """
  GETs `url` through the rate limiter and decodes the JSON body.

  Options:
    * `:bucket` (required): rate-limiter bucket, e.g. `:trade_leagues`. One
      bucket per endpoint family; the limiter maps buckets to GGG policies.
    * `:limiter`: limiter server (default `#{inspect(RateLimiter)}`).
    * `:adapter`: see the moduledoc (default from `Quicksilver.Integrations.Config`).
    * `:timeout`: whole-request timeout in ms once a slot is granted (default 30 s).

  Returns `{:ok, json, response}` for a 2xx JSON response, else
  `{:error, reason}` (`t:error/0`). Non-2xx responses are errors; the limiter
  still sees their headers (a 429 pauses the policy).
  """
  @spec get_json(String.t(), keyword()) :: {:ok, term(), Response.t()} | {:error, error()}
  def get_json(url, opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    limiter = Keyword.get(opts, :limiter, RateLimiter)

    {adapter, adapter_opts} =
      normalize_adapter(
        Keyword.get_lazy(opts, :adapter, &Quicksilver.Integrations.Config.http_adapter/0)
      )

    adapter_opts = Keyword.put_new(adapter_opts, :timeout, Keyword.get(opts, :timeout, 30_000))

    headers = [
      {"user-agent", user_agent()},
      {"accept", "application/json"},
      {"accept-encoding", "gzip"}
    ]

    {:ok, ticket} = RateLimiter.acquire(limiter, bucket)

    result =
      try do
        adapter.request("GET", url, headers, nil, adapter_opts)
      catch
        kind, reason -> {:error, {:transport, {kind, reason}}}
      end

    RateLimiter.release(limiter, ticket, outcome(result))

    with {:ok, %Response{} = resp} <- normalize_result(result),
         :ok <- check_status(resp),
         {:ok, body} <- decompress(resp),
         {:ok, json} <- decode(body) do
      {:ok, json, %{resp | body: body}}
    end
  end

  @doc "Short plain-language description of an error, for `Health` details."
  @spec describe_error(term()) :: String.t()
  def describe_error({:http_status, status}), do: "HTTP #{status}"
  def describe_error({:transport, :timeout}), do: "network timeout"
  def describe_error({:transport, _}), do: "network error"
  def describe_error({:decode, _}), do: "unexpected response"
  def describe_error(:http_disabled), do: "network access disabled"
  def describe_error(:unsupported_type), do: "type not supported by source"
  def describe_error(:league_not_covered), do: "no data for this league"
  def describe_error(:bad_shape), do: "unexpected response"
  def describe_error(:no_divine_rate), do: "unexpected response"
  def describe_error({:task_crash, _}), do: "internal error"
  def describe_error(_), do: "request failed"

  # --- Helpers ----------------------------------------------------------------

  defp normalize_adapter({mod, adapter_opts}) when is_atom(mod), do: {mod, adapter_opts}
  defp normalize_adapter(mod) when is_atom(mod), do: {mod, []}

  defp outcome({:ok, %Response{status: s, headers: h}}), do: {:response, s, h}
  defp outcome(_), do: :error

  defp normalize_result({:ok, %Response{}} = ok), do: ok
  defp normalize_result({:error, :http_disabled}), do: {:error, :http_disabled}
  defp normalize_result({:error, {:transport, _}} = e), do: e
  defp normalize_result({:error, reason}), do: {:error, {:transport, reason}}

  defp check_status(%Response{status: s}) when s in 200..299, do: :ok
  defp check_status(%Response{status: s}), do: {:error, {:http_status, s}}

  defp decompress(resp) do
    case resp |> Response.header("content-encoding") |> normalize_encoding() do
      nil ->
        {:ok, resp.body}

      "identity" ->
        {:ok, resp.body}

      "gzip" ->
        try do
          {:ok, :zlib.gunzip(resp.body)}
        rescue
          e -> {:error, {:decode, {:gzip, e}}}
        end

      other ->
        {:error, {:decode, {:content_encoding, other}}}
    end
  end

  defp normalize_encoding(nil), do: nil
  defp normalize_encoding(v), do: v |> String.trim() |> String.downcase()

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, json} -> {:ok, json}
      {:error, e} -> {:error, {:decode, e}}
    end
  end
end
