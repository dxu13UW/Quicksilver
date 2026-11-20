defmodule Quicksilver.Integrations.Urls do
  @moduledoc """
  Every external URL the backend calls, in one place (docs/DATA_SOURCES.md).

  poe.ninja moved its PoE 1 API on or before 2026-11-15 (`/api/data/*` now 404).
  When a host moves an endpoint again, this file is the only one to change.
  Query strings are encoded per RFC 3986 (`%20` for spaces, as in
  `Hardcore Covens`).
  """

  @pathofexile "https://www.pathofexile.com"
  @poe_ninja "https://poe.ninja"

  # --- www.pathofexile.com ----------------------------------------------------

  @doc "Trade league list (preferred league source). Filter `realm == \"pc\"`."
  @spec trade_leagues() :: String.t()
  def trade_leagues, do: @pathofexile <> "/api/trade/data/leagues"

  # --- poe.ninja ----------------------------------------------------------------

  @doc "poe.ninja index state: which leagues poe.ninja has economy data for."
  @spec poe_ninja_index_state() :: String.t()
  def poe_ninja_index_state, do: @poe_ninja <> "/poe1/api/data/index-state"

  @doc "poe.ninja exchange overview (currency, fragments, cards, essences, ...)."
  @spec poe_ninja_exchange_overview(String.t(), String.t()) :: String.t()
  def poe_ninja_exchange_overview(league, type),
    do: @poe_ninja <> "/poe1/api/economy/exchange/current/overview?" <> query(league, type)

  @doc "poe.ninja stash item overview (uniques, gems, maps, bases, ...)."
  @spec poe_ninja_stash_overview(String.t(), String.t()) :: String.t()
  def poe_ninja_stash_overview(league, type),
    do: @poe_ninja <> "/poe1/api/economy/stash/current/item/overview?" <> query(league, type)

  defp query(league, type),
    do: URI.encode_query([{"league", league}, {"type", type}], :rfc3986)
end
