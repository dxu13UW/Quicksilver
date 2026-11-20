defmodule Quicksilver.Integrations do
  @moduledoc """
  Public API of the data sources (integrations lane), for the gateway's
  Dashboard routes (PROTOCOL.md "Dashboard"). Everything here talks to the
  processes under `Quicksilver.Integrations.Supervisor`; nothing blocks on the
  network unless no data is cached yet.

  ## Leagues (`leagues.list`, `league.set`)

      {:ok, [%{id: "Covens", text: "Covens"}, ...]} = Integrations.list_leagues()
      "Covens" = Integrations.current_league()          # or nil
      :ok = Integrations.set_league("Standard")
      {:error, :unknown_league} = Integrations.set_league("Foo")

  ## Rates (`rates.subscribe`, `rates.update`)

      {:ok, rates} = Integrations.rates()
      # rates = %{league:, source: "poe_ninja", fetched_at: DateTime, stale:,
      #           divine_chaos:, rates: [%{id:, name:, chaos:, divine:, change_7d:, volume_chaos:}]}

  The map has exactly the `rates.update` payload fields; only `fetched_at` is a
  `DateTime` (format it with `Quicksilver.Time.iso8601_ms/1`).

  ## Subscriptions

      :ok = Integrations.subscribe(:rates)
      :ok = Integrations.subscribe(:league)

  The calling process then receives:

    * `{Quicksilver.Integrations, :rates, rates}` when the current league's
      rates are refreshed, and right after a league change if rates for the
      new league are cached (otherwise after they are fetched);
    * `{Quicksilver.Integrations, :league_changed, league_id}` on every
      successful `set_league/1` (even to the same league) and whenever the
      backend picks a league itself (default or fallback).

  Subscriptions end with `unsubscribe/1` or when the process exits.

  ## Error mapping suggested for the gateway

  | this API | PROTOCOL error code |
  |---|---|
  | `{:error, :unknown_league}` | `unknown_league` |
  | `{:error, :unavailable}`, `:no_league`, `:league_not_covered` | `upstream_unavailable` |
  | `{:error, {:settings, _}}` | `internal` |
  """

  alias Quicksilver.Integrations.{Leagues, PoeNinja, PubSub}

  @doc "PC leagues in source order. See `Quicksilver.Integrations.Leagues.list/2`."
  @spec list_leagues(timeout()) ::
          {:ok, [%{id: String.t(), text: String.t()}]} | {:error, :unavailable}
  def list_leagues(timeout \\ 15_000), do: Leagues.list(Leagues, timeout)

  @doc "The current league id, or nil if none is known yet."
  @spec current_league() :: String.t() | nil
  def current_league, do: Leagues.current(Leagues)

  @doc "Selects and saves a league. See `Quicksilver.Integrations.Leagues.set_current/2`."
  @spec set_league(String.t()) ::
          :ok | {:error, :unknown_league | :unavailable | {:settings, term()}}
  def set_league(league_id), do: Leagues.set_current(Leagues, league_id)

  @doc "Cached currency rates for the current league. See `Quicksilver.Integrations.PoeNinja.rates/2`."
  @spec rates(keyword()) ::
          {:ok, PoeNinja.rates()} | {:error, :no_league | :league_not_covered | :unavailable}
  def rates(opts \\ []), do: PoeNinja.rates(PoeNinja, opts)

  @doc "Cached prices for a tracked poe.ninja type. See `Quicksilver.Integrations.PoeNinja.items/3`."
  @spec item_prices(String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def item_prices(type, opts \\ []), do: PoeNinja.items(PoeNinja, type, opts)

  @doc "Subscribes the calling process to `:rates` or `:league`. Idempotent."
  @spec subscribe(PubSub.topic()) :: :ok
  def subscribe(topic) when topic in [:rates, :league], do: PubSub.subscribe(PubSub, topic)

  @doc "Unsubscribes the calling process from `topic`."
  @spec unsubscribe(PubSub.topic()) :: :ok
  def unsubscribe(topic) when topic in [:rates, :league], do: PubSub.unsubscribe(PubSub, topic)
end
