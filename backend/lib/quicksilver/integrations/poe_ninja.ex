defmodule Quicksilver.Integrations.PoeNinja do
  @moduledoc """
  poe.ninja client (PLAN I1): keeps the tracked overviews fresh for the
  current league and serves them from cache.

  ## What is tracked

  `:types` (default from `Quicksilver.Integrations.Config`, key
  `:poe_ninja_types`): a list of `{:exchange | :stash, type}`. Week 2 tracks
  `{:exchange, "Currency"}` (feeds `rates.update`) and
  `{:stash, "UniqueAccessory"}` (the one item category). Before fetching a
  league, the index-state endpoint is consulted (cached 1 h) and leagues
  poe.ninja doesn't cover (e.g. Ruthless) are not requested at all.

  ## Cache and refresh schedule (DATA_SOURCES.md "Caching policy")

  * Key: league + kind + type. In memory.
  * Freshness: `max-age - Age` from the response (`CacheControl.ttl_s/3`);
    fallback `:fallback_ttl_s` (1800 s) when the header is missing or
    `no-cache`; never below `:floor_ttl_s` (60 s).
  * Each overview is refetched when it expires. Nothing is refetched early.
  * On error the old data is served, flagged `stale: true`, for up to the
    response's `stale-if-error` (fallback `:stale_fallback_s`, 86,400 s).
    Retries back off from `:retry_base_s` (60 s), doubling, capped at
    `:retry_max_s` (1800 s).
  * index-state: TTL `:index_ttl_s` (3600 s).
  * A league change keeps the other league's entries; switching back uses them
    if still fresh.

  Requests go out one at a time (bucket `:poe_ninja`; poe.ninja sends no
  rate-limit headers) from a task, so reads never wait for the network unless
  there is nothing cached yet (see `rates/2`).

  ## Pushes

  On the `:rates` topic of `Quicksilver.Integrations.PubSub`, this server
  broadcasts `{Quicksilver.Integrations, :rates, rates}` (shape: `rates/2`)
  for the current league whenever:

  * the Currency overview is refreshed (success), or
  * the current league changes and cached rates exist for the new league (sent
    at once; a fetch follows if they are missing or expired).

  ## Health

  `poe_ninja`: `ok` (everything fresh), `degraded` (a refresh failed, cached
  data served as stale), `down` (no usable Currency data, or the league isn't
  covered by poe.ninja). Stays `idle` until a league is known and a fetch ran.
  """

  use GenServer
  require Logger

  alias Quicksilver.Health
  alias Quicksilver.Integrations.{CacheControl, Config, HTTP, Leagues, Parser, PubSub, Urls}

  @rates_key_type {:exchange, "Currency"}

  @defaults [
    fallback_ttl_s: 1800,
    floor_ttl_s: 60,
    stale_fallback_s: 86_400,
    index_ttl_s: 3600,
    retry_base_s: 60,
    retry_max_s: 1800
  ]

  @type rates :: %{
          league: String.t(),
          source: String.t(),
          fetched_at: DateTime.t(),
          stale: boolean(),
          divine_chaos: float(),
          rates: [Parser.rate_row()]
        }

  # --- Public API -------------------------------------------------------------

  @doc """
  Options: `:name`, `:pubsub`, `:health`, `:leagues` (servers), `:task_sup`,
  `:http` (keyword for `HTTP.get_json/2`), `:auto_refresh`, `:types`, and the
  TTL keys in the moduledoc.
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Cached currency rates, ready to become a `rates.update` payload:

      %{league: "Covens", source: "poe_ninja", fetched_at: ~U[...], stale: false,
        divine_chaos: 216.2,
        rates: [%{id: "divine", name: "Divine Orb", chaos: 216.2, divine: 1.0,
                  change_7d: 245.4, volume_chaos: 12321486.0}, ...]}

  `fetched_at` is a `DateTime` (format it with `Quicksilver.Time.iso8601_ms/1`).
  Rows are sorted by `chaos`, descending; `change_7d` and `volume_chaos` may be nil.

  Options: `:league` (default: the current league), `:timeout` (default
  15 000 ms). If nothing is cached for the current league yet, waits for the
  fetch in flight (or starts one, unless a failed attempt is backing off).

  **Cold start:** if no league has been chosen yet, the call first waits for
  `Leagues` to choose one (saved setting, list default, or the `Standard`
  fallback; it also nudges `Leagues` to fetch), then for that league's rates,
  all within `:timeout`.

  Errors: `:no_league` (the timeout passed and still no league was chosen),
  `:league_not_covered` (poe.ninja
  has no data for it), `:unavailable` (no usable cache and the fetch failed or
  timed out).
  """
  @spec rates(GenServer.server(), keyword()) ::
          {:ok, rates()} | {:error, :no_league | :league_not_covered | :unavailable}
  def rates(server \\ __MODULE__, opts \\ []) do
    GenServer.call(
      server,
      {:rates, Keyword.get(opts, :league)},
      Keyword.get(opts, :timeout, 15_000)
    )
  catch
    # The late reply (if any) is dropped by the call's alias. Tell apart "still
    # no league" from "league known but no data in time".
    :exit, {:timeout, _} ->
      if GenServer.call(server, :league) == nil,
        do: {:error, :no_league},
        else: {:error, :unavailable}
  end

  @doc """
  Cached lines of a tracked overview type (e.g. `"UniqueAccessory"`), never
  waiting for the network:

      %{league: "Covens", type: "UniqueAccessory", fetched_at: ~U[...], stale: false,
        items: [%{name:, base_type:, variant:, links:, item_type:, gem_level:,
                  gem_quality:, corrupted:, chaos:, divine:, listing_count:,
                  details_id:}, ...]}

  For an exchange type, `items` are the rate rows from `rates/2`.
  Errors: `:not_tracked`, `:no_league`, `:league_not_covered`, `:unavailable`.
  """
  @spec items(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def items(server \\ __MODULE__, type, opts \\ []),
    do: GenServer.call(server, {:items, type, Keyword.get(opts, :league)})

  @doc "Starts a refresh now for anything missing or expired (no early refetch). Async."
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__), do: GenServer.cast(server, :refresh)

  # --- GenServer --------------------------------------------------------------

  @impl true
  def init(opts) do
    opts = Keyword.merge(@defaults, opts)
    pubsub = Keyword.get(opts, :pubsub, PubSub)
    PubSub.subscribe(pubsub, :league)

    state = %{
      pubsub: pubsub,
      health: Keyword.get(opts, :health, Health),
      task_sup: Keyword.get(opts, :task_sup, Quicksilver.Integrations.TaskSupervisor),
      http: Keyword.get(opts, :http, []),
      auto_refresh: Keyword.get_lazy(opts, :auto_refresh, fn -> Config.get(:auto_refresh) end),
      types: Keyword.get_lazy(opts, :types, fn -> Config.get(:poe_ninja_types) end),
      # Durations in seconds, as given; converted where used.
      cfg: Map.new(Keyword.take(opts, Keyword.keys(@defaults))),
      leagues: Keyword.get(opts, :leagues, Leagues),
      # Subscribed to :league above, so no change can slip between these two.
      league: Leagues.current(Keyword.get(opts, :leagues, Leagues)),
      # rates/2 callers waiting for the first league (cold start).
      league_waiters: [],
      entries: %{},
      failures: %{},
      index: nil,
      cycle: nil,
      waiters: [],
      timer: nil
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    {:noreply, if(state.auto_refresh, do: maybe_cycle(state), else: state)}
  end

  @impl true
  # Cold start: no league chosen yet. Wait for Leagues to pick one (saved
  # setting, list default or Standard fallback; it broadcasts :league_changed),
  # and nudge it to fetch the list in case nothing else has. The caller's
  # timeout bounds the wait (PROTOCOL rates.subscribe).
  def handle_call({:rates, nil}, from, %{league: nil} = state) do
    Leagues.refresh(state.leagues)
    {:noreply, %{state | league_waiters: [from | state.league_waiters]}}
  end

  def handle_call({:rates, league}, from, state),
    do: {:noreply, serve_rates(state, from, league || state.league)}

  def handle_call(:league, _from, state), do: {:reply, state.league, state}

  def handle_call({:items, type, league}, _from, state) do
    league = league || state.league

    reply =
      case Enum.find(state.types, fn {_kind, t} -> t == type end) do
        nil ->
          {:error, :not_tracked}

        {_kind, _} when league == nil ->
          {:error, :no_league}

        {kind, _} ->
          case valid_entry(state, {league, kind, type}) do
            nil ->
              {:error, missing_reason(state, league)}

            entry ->
              items = if kind == :exchange, do: entry.data.rows, else: entry.data

              {:ok,
               %{
                 league: league,
                 type: type,
                 fetched_at: entry.fetched_at,
                 stale: entry.failed,
                 items: items
               }}
          end
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, maybe_cycle(state)}

  @impl true
  def handle_info(:refresh, state), do: {:noreply, maybe_cycle(%{state | timer: nil})}

  def handle_info({Quicksilver.Integrations, :league_changed, league}, state) do
    state = %{state | league: league}

    # Callers that waited for the first league now wait for its rates.
    {pending, state} = {Enum.reverse(state.league_waiters), %{state | league_waiters: []}}
    state = Enum.reduce(pending, state, &serve_rates(&2, &1, league))

    case lookup_rates(state, league) do
      {:ok, rates} -> PubSub.broadcast(state.pubsub, :rates, :rates, rates)
      _ -> :ok
    end

    state = report_health(state)
    {:noreply, if(state.auto_refresh, do: maybe_cycle(state), else: state)}
  end

  def handle_info({ref, result}, %{cycle: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_cycle(state, result)}
  end

  def handle_info(
        {:DOWN, ref, :process, _, reason},
        %{cycle: %{ref: ref, league: league}} = state
      ) do
    Logger.error("poe.ninja: refresh task crashed: #{inspect(reason)}")
    result = %{league: league, index: :skip, types: [], crashed: {:task_crash, reason}}
    {:noreply, finish_cycle(state, result)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Replies at once from cache, or queues `from` behind the cycle that will
  # fetch `league`. Returns the new state.
  defp serve_rates(state, from, league) do
    case lookup_rates(state, league) do
      {:ok, _} = ok ->
        GenServer.reply(from, ok)
        state

      error ->
        cond do
          league == nil or league != state.league ->
            GenServer.reply(from, error)
            state

          # A cycle is running (possibly for the previous league): wait for it;
          # finish_cycle/2 starts the next one for the current league.
          state.cycle != nil ->
            %{state | waiters: [{from, league} | state.waiters]}

          plan(state, league) != nil ->
            state = start_cycle(state, league)
            %{state | waiters: [{from, league} | state.waiters]}

          true ->
            GenServer.reply(from, error)
            state
        end
    end
  end

  # --- Planning ---------------------------------------------------------------

  defp maybe_cycle(%{league: nil} = state), do: state
  defp maybe_cycle(%{cycle: %{}} = state), do: state

  defp maybe_cycle(state) do
    if plan(state, state.league),
      do: start_cycle(state, state.league),
      else: schedule(state)
  end

  # nil if nothing needs fetching for `league`, else {need_index?, due_keys}.
  defp plan(state, league) do
    now = now()
    index_fresh? = state.index != nil and now < state.index.expires_at

    cond do
      league == nil ->
        nil

      index_fresh? and league not in state.index.leagues ->
        nil

      true ->
        due =
          for {kind, type} <- state.types,
              due?(state, {league, kind, type}, now),
              do: {league, kind, type}

        if due == [], do: nil, else: {not index_fresh?, due}
    end
  end

  defp due?(state, key, now) do
    entry = Map.get(state.entries, key)

    case Map.get(state.failures, key) do
      %{retry_at: t} when now < t -> false
      _ -> entry == nil or entry.failed or now >= entry.expires_at
    end
  end

  defp start_cycle(state, league) do
    {need_index, due} = plan(state, league)
    known = state.index && state.index.leagues
    http = Keyword.put(state.http, :bucket, :poe_ninja)
    cfg = state.cfg

    task =
      Task.Supervisor.async_nolink(state.task_sup, fn ->
        run_cycle(league, need_index, known, due, http, cfg)
      end)

    %{state | cycle: %{ref: task.ref, league: league}}
  end

  # --- The fetch cycle (runs in a task) ---------------------------------------

  defp run_cycle(league, need_index, known, due, http, cfg) do
    index =
      if need_index do
        with {:ok, json, _} <- HTTP.get_json(Urls.poe_ninja_index_state(), http),
             {:ok, names} <- Parser.ninja_economy_leagues(json) do
          {:ok, names}
        end
      else
        :skip
      end

    names =
      case index do
        {:ok, names} -> names
        _ -> known
      end

    types =
      if names != nil and league not in names do
        :not_covered
      else
        for {^league, kind, type} = key <- due,
            do: {key, fetch_type(league, kind, type, http, cfg)}
      end

    %{league: league, index: index, types: types}
  end

  defp fetch_type(league, kind, type, http, cfg) do
    {url, parse} =
      case kind do
        :exchange -> {Urls.poe_ninja_exchange_overview(league, type), &Parser.exchange_rates/1}
        :stash -> {Urls.poe_ninja_stash_overview(league, type), &Parser.stash_items/1}
      end

    with {:ok, json, resp} <- HTTP.get_json(url, http),
         {:ok, data} <- parse.(json) do
      ttl_ms = CacheControl.ttl_s(resp.headers, cfg.fallback_ttl_s, cfg.floor_ttl_s) * 1000
      stale_ms = CacheControl.stale_if_error_s(resp.headers, cfg.stale_fallback_s) * 1000
      {:ok, data, ttl_ms, stale_ms}
    end
  end

  # --- Applying results -------------------------------------------------------

  defp finish_cycle(state, result) do
    now = now()
    league = result.league
    state = %{state | cycle: nil}

    state =
      case result.index do
        {:ok, names} ->
          %{state | index: %{leagues: names, expires_at: now + state.cfg.index_ttl_s * 1000}}

        {:error, reason} ->
          log_error("index-state", reason, state)

        :skip ->
          state
      end

    {state, rates_refreshed?} =
      case result.types do
        :not_covered ->
          Logger.info("poe.ninja: no economy data for league #{inspect(league)}")
          {state, false}

        list ->
          Enum.reduce(list, {state, false}, fn {key, res}, {state, refreshed?} ->
            state = apply_type(state, key, res, now)
            refreshed? = refreshed? or (match?({:ok, _, _, _}, res) and rates_key?(key))
            {state, refreshed?}
          end)
      end

    state =
      case Map.get(result, :crashed) do
        nil ->
          state

        reason ->
          due = for {kind, type} <- state.types, do: {league, kind, type}
          Enum.reduce(due, state, &apply_type(&2, &1, {:error, reason}, now))
      end

    if rates_refreshed? and league == state.league do
      {:ok, rates} = lookup_rates(state, league)
      PubSub.broadcast(state.pubsub, :rates, :rates, rates)
    end

    state = reply_waiters(state, league)
    state = if league == state.league, do: report_health(state), else: state

    # The league may have changed while the cycle ran: plan again at once.
    # Without auto refresh, only callers still waiting justify another cycle.
    state =
      if state.auto_refresh or state.waiters != [],
        do: maybe_cycle(state),
        else: state

    # Nothing more will be fetched for anyone still waiting: answer them now.
    if state.cycle == nil, do: reply_all_waiters(state), else: state
  end

  defp reply_all_waiters(state) do
    for {from, league} <- state.waiters, do: GenServer.reply(from, lookup_rates(state, league))
    %{state | waiters: []}
  end

  defp apply_type(state, key, {:ok, data, ttl_ms, stale_ms}, now) do
    entry = %{
      data: data,
      fetched_at: DateTime.utc_now(),
      expires_at: now + ttl_ms,
      stale_until: now + stale_ms,
      failed: false,
      error: nil
    }

    %{
      state
      | entries: Map.put(state.entries, key, entry),
        failures: Map.delete(state.failures, key)
    }
  end

  defp apply_type(state, key, {:error, reason}, now) do
    state = log_error(inspect(key), reason, state)
    n = get_in(state.failures, [key, :n]) || 0
    retry_ms = min(state.cfg.retry_base_s * Integer.pow(2, n), state.cfg.retry_max_s) * 1000

    entries =
      case Map.get(state.entries, key) do
        nil -> state.entries
        entry -> Map.put(state.entries, key, %{entry | failed: true, error: reason})
      end

    %{
      state
      | entries: entries,
        failures:
          Map.put(state.failures, key, %{n: n + 1, retry_at: now + retry_ms, error: reason})
    }
  end

  defp log_error(what, reason, state) do
    Logger.warning("poe.ninja: #{what} failed: #{inspect(reason)}")
    state
  end

  defp reply_waiters(state, league) do
    {mine, others} = Enum.split_with(state.waiters, fn {_from, l} -> l == league end)

    for {from, _} <- mine, do: GenServer.reply(from, lookup_rates(state, league))
    %{state | waiters: others}
  end

  defp schedule(%{auto_refresh: false} = state), do: state
  defp schedule(%{league: nil} = state), do: state

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    now = now()
    league = state.league

    times =
      if covered?(state, league) == false do
        [state.index.expires_at]
      else
        for {kind, type} <- state.types do
          key = {league, kind, type}

          case {Map.get(state.failures, key), Map.get(state.entries, key)} do
            {%{retry_at: t}, _} -> t
            {nil, %{expires_at: t}} -> t
            {nil, nil} -> now
          end
        end
      end

    delay = max(Enum.min(times) - now, 1000)
    %{state | timer: Process.send_after(self(), :refresh, delay)}
  end

  # --- Reading the cache ------------------------------------------------------

  defp lookup_rates(_state, nil), do: {:error, :no_league}

  defp lookup_rates(state, league) do
    {kind, type} = @rates_key_type

    case valid_entry(state, {league, kind, type}) do
      nil ->
        {:error, missing_reason(state, league)}

      entry ->
        {:ok,
         %{
           league: league,
           source: "poe_ninja",
           fetched_at: entry.fetched_at,
           stale: entry.failed,
           divine_chaos: entry.data.divine_chaos,
           rates: entry.data.rows
         }}
    end
  end

  defp valid_entry(state, key) do
    case Map.get(state.entries, key) do
      %{stale_until: t} = entry -> if now() < t, do: entry, else: nil
      nil -> nil
    end
  end

  defp missing_reason(state, league),
    do: if(covered?(state, league) == false, do: :league_not_covered, else: :unavailable)

  # true / false from a fresh index, :unknown otherwise.
  defp covered?(%{index: nil}, _league), do: :unknown

  defp covered?(%{index: index}, league) do
    cond do
      now() >= index.expires_at -> :unknown
      league in index.leagues -> true
      true -> false
    end
  end

  defp rates_key?({_league, kind, type}), do: {kind, type} == @rates_key_type

  # --- Health -----------------------------------------------------------------

  defp report_health(%{league: nil} = state), do: state

  defp report_health(state) do
    league = state.league
    keys = for {kind, type} <- state.types, do: {league, kind, type}
    valid = for k <- keys, e = valid_entry(state, k), do: {k, e}
    failed = for k <- keys, f = Map.get(state.failures, k), do: {k, f}
    rates_entry = Enum.find_value(valid, fn {k, e} -> if rates_key?(k), do: e end)

    attrs =
      cond do
        covered?(state, league) == false ->
          [status: :down, cached_at: nil, detail: "poe.ninja has no data for #{league}"]

        rates_entry == nil and failed != [] ->
          {_, f} = hd(failed)
          [status: :down, cached_at: nil, detail: HTTP.describe_error(f.error)]

        rates_entry == nil ->
          nil

        failed != [] ->
          {_, f} = hd(failed)

          [
            status: :degraded,
            cached_at: oldest(valid),
            detail: "showing cached data: " <> HTTP.describe_error(f.error)
          ]

        true ->
          [status: :ok, cached_at: oldest(valid), last_success: newest(valid), detail: nil]
      end

    if attrs, do: Health.report(state.health, :poe_ninja, attrs)
    state
  end

  defp oldest(valid), do: valid |> Enum.map(fn {_, e} -> e.fetched_at end) |> Enum.min(DateTime)
  defp newest(valid), do: valid |> Enum.map(fn {_, e} -> e.fetched_at end) |> Enum.max(DateTime)

  defp now, do: System.monotonic_time(:millisecond)
end
