defmodule Quicksilver.Integrations.CacheControl do
  @moduledoc """
  Turns `Cache-Control` and `Age` response headers into cache lifetimes
  (DATA_SOURCES.md "Caching policy").

  * **Freshness** = `max-age - Age`: poe.ninja sits behind Cloudflare, and a
    cached response with `Age: 253` and `max-age=1800` only has 1547 s of
    freshness left. Refetching earlier would just get the same CDN copy.
    If the header is missing, `no-cache`, `no-store` or `max-age=0`, the caller's
    fallback TTL is used. The result is never below `floor_s`, so a nearly
    expired CDN copy can't cause a tight refetch loop.
  * **Stale-if-error** = `stale-if-error` directive, else the caller's fallback.
  """

  alias Quicksilver.Integrations.HTTP.Response

  @type directives :: %{
          max_age: non_neg_integer() | nil,
          no_cache: boolean(),
          stale_if_error: non_neg_integer() | nil,
          age: non_neg_integer()
        }

  @doc "Parses the relevant directives from response headers."
  @spec parse([{String.t(), String.t()}]) :: directives()
  def parse(headers) do
    directives =
      (Response.header(headers, "cache-control") || "")
      |> String.split(",", trim: true)
      |> Map.new(fn part ->
        case String.split(String.trim(part), "=", parts: 2) do
          [k, v] -> {String.downcase(k), String.trim(v, "\"")}
          [k] -> {String.downcase(k), true}
        end
      end)

    %{
      max_age: int(directives["max-age"]),
      no_cache: Map.has_key?(directives, "no-cache") or Map.has_key?(directives, "no-store"),
      stale_if_error: int(directives["stale-if-error"]),
      age: int(Response.header(headers, "age")) || 0
    }
  end

  @doc "Freshness in seconds; see the moduledoc."
  @spec ttl_s([{String.t(), String.t()}], pos_integer(), non_neg_integer()) :: pos_integer()
  def ttl_s(headers, fallback_s, floor_s) do
    d = parse(headers)

    ttl =
      cond do
        d.no_cache -> fallback_s
        d.max_age in [nil, 0] -> fallback_s
        true -> d.max_age - d.age
      end

    max(ttl, floor_s)
  end

  @doc "How long past fetch time stale data may still be served after errors, in seconds."
  @spec stale_if_error_s([{String.t(), String.t()}], pos_integer()) :: pos_integer()
  def stale_if_error_s(headers, fallback_s) do
    case parse(headers) do
      %{stale_if_error: s} when is_integer(s) and s > 0 -> s
      _ -> fallback_s
    end
  end

  defp int(nil), do: nil
  defp int(true), do: nil

  defp int(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end
end
