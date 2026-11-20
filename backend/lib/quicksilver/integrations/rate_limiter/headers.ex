defmodule Quicksilver.Integrations.RateLimiter.Headers do
  @moduledoc """
  Parses GGG's `x-rate-limit-*` headers (DATA_SOURCES.md "Reading GGG rate-limit
  headers"). Pure functions; no state.

      x-rate-limit-policy: trade-search-request-limit
      x-rate-limit-rules: Ip
      x-rate-limit-ip: 5:10:60,15:60:300
      x-rate-limit-ip-state: 1:10:0,1:60:0

  Each tier is `max:period:restriction` and each state tier is
  `current:period:active_restriction`, all integers (seconds).
  """

  alias Quicksilver.Integrations.HTTP.Response

  @type tier :: %{max: pos_integer(), period_s: pos_integer(), restriction_s: non_neg_integer()}
  @type state_tier :: %{
          current: non_neg_integer(),
          period_s: pos_integer(),
          active_s: non_neg_integer()
        }
  @type rule :: %{name: String.t(), tiers: [tier()], state: [state_tier()]}
  @type t :: %{policy: String.t(), rules: [rule()]}

  @doc """
  Returns the policy and its rules, or `nil` if the response carries no
  `x-rate-limit-policy` header (poe.ninja and the trade `data/*` endpoints).
  Malformed tiers are skipped rather than guessed.
  """
  @spec parse([{String.t(), String.t()}]) :: t() | nil
  def parse(headers) do
    case Response.header(headers, "x-rate-limit-policy") do
      nil ->
        nil

      policy ->
        rules =
          (Response.header(headers, "x-rate-limit-rules") || "")
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(fn name ->
            key = "x-rate-limit-" <> String.downcase(name)

            %{
              name: name,
              tiers: headers |> Response.header(key) |> triples() |> Enum.flat_map(&tier/1),
              state:
                headers
                |> Response.header(key <> "-state")
                |> triples()
                |> Enum.flat_map(&state/1)
            }
          end)

        %{policy: String.trim(policy), rules: rules}
    end
  end

  @doc "`Retry-After` in whole seconds, or nil (HTTP-date form is not used by GGG)."
  @spec retry_after_s([{String.t(), String.t()}]) :: non_neg_integer() | nil
  def retry_after_s(headers) do
    with v when is_binary(v) <- Response.header(headers, "retry-after"),
         {n, ""} when n >= 0 <- Integer.parse(String.trim(v)) do
      n
    else
      _ -> nil
    end
  end

  defp triples(nil), do: []

  defp triples(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(fn part ->
      part |> String.trim() |> String.split(":") |> Enum.map(&Integer.parse/1)
    end)
  end

  defp tier([{max, ""}, {period, ""}, {restr, ""}]) when max > 0 and period > 0 and restr >= 0,
    do: [%{max: max, period_s: period, restriction_s: restr}]

  defp tier(_), do: []

  defp state([{cur, ""}, {period, ""}, {active, ""}])
       when cur >= 0 and period > 0 and active >= 0,
       do: [%{current: cur, period_s: period, active_s: active}]

  defp state(_), do: []
end
