defmodule Quicksilver.Integrations.Leagues do
  @moduledoc """
  League list (PLAN I2) and the current league selection.

  **Source:** the trade league list (`Urls.trade_leagues/0`), filtered to
  `realm == "pc"` and kept in source order (ADR-004, PROTOCOL `leagues.list`).
  Its ids are the names the trade API and poe.ninja expect.

  **Cache:** in memory, TTL `:ttl_s` (default 3600 s, DATA_SOURCES.md; the
  header says 120 s, and a longer TTL is allowed). Fetched at startup, then
  once per TTL. On a failed refresh the previous list keeps being served for
  the rest of the run (leagues only change at league start or end) and Health
  shows `degraded`. Retries after failures back off from `:retry_base_s`
  (60 s), doubling, up to the TTL.

  **Current league** (PROTOCOL "Default league"):

  1. the league saved in `Quicksilver.Settings` under `"league"`, if it is in the
     list (or while the list hasn't loaded yet);
  2. otherwise the first PC league in the list (the current challenge league);
  3. otherwise, if the list can't be fetched, `"Standard"`.

  A saved league that is no longer in the list (e.g. the league ended) is
  replaced by the default for this run, without overwriting the saved value.
  Only `set_current/2` writes the setting.

  Every change of the current league, and every successful `set_current/2`
  (even to the same league, so a fresh `rates.update` follows per PROTOCOL),
  is broadcast as `{Quicksilver.Integrations, :league_changed, id}` on the
  `:league` topic (`Quicksilver.Integrations.PubSub`).

  **Health:** reports `trade_leagues` as `ok` / `degraded` / `down`.
  """

  use GenServer
  require Logger

  alias Quicksilver.Health
  alias Quicksilver.Integrations.{Config, HTTP, Parser, PubSub, Urls}

  @default_ttl_s 3600
  @default_retry_base_s 60
  @fallback_league "Standard"

  @type league :: Parser.league()

  # --- Public API -------------------------------------------------------------

  @doc """
  Options: `:name`, `:pubsub`, `:health`, `:settings` (servers), `:task_sup`,
  `:http` (keyword passed to `HTTP.get_json/2`: `:adapter`, `:limiter`),
  `:auto_refresh` (default from `Config`), `:ttl_s`, `:retry_base_s`.
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  PC leagues in source order. If nothing is cached yet, waits for the fetch in
  flight (or starts one, unless a failed attempt is still backing off), up to
  `timeout` ms. `{:error, :unavailable}` if there is no list to serve.
  """
  @spec list(GenServer.server(), timeout()) :: {:ok, [league()]} | {:error, :unavailable}
  def list(server \\ __MODULE__, timeout \\ 15_000) do
    GenServer.call(server, :list, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :unavailable}
  end

  @doc "The current league id, or nil before anything is known (no saved league, list not loaded yet)."
  @spec current(GenServer.server()) :: String.t() | nil
  def current(server \\ __MODULE__), do: GenServer.call(server, :current)

  @doc """
  Selects `league_id`, saves it to `settings.json` and broadcasts
  `:league_changed`.

  Errors: `:unknown_league` (not in the list), `:unavailable` (no list to
  validate against), `{:settings, reason}` (the file write failed; nothing
  changed).
  """
  @spec set_current(GenServer.server(), String.t()) ::
          :ok | {:error, :unknown_league | :unavailable | {:settings, term()}}
  def set_current(server \\ __MODULE__, league_id),
    do: GenServer.call(server, {:set_current, league_id})

  @doc "Fetches now if the cache is missing or expired and no fetch is running. Async."
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__), do: GenServer.cast(server, :refresh)

  # --- GenServer --------------------------------------------------------------

  @impl true
  def init(opts) do
    settings = Keyword.get(opts, :settings, Quicksilver.Settings)

    saved =
      case Quicksilver.Settings.get(settings, "league", nil) do
        s when is_binary(s) and s != "" -> s
        _ -> nil
      end

    state = %{
      pubsub: Keyword.get(opts, :pubsub, PubSub),
      health: Keyword.get(opts, :health, Health),
      settings: settings,
      task_sup: Keyword.get(opts, :task_sup, Quicksilver.Integrations.TaskSupervisor),
      http: Keyword.get(opts, :http, []),
      auto_refresh: Keyword.get_lazy(opts, :auto_refresh, fn -> Config.get(:auto_refresh) end),
      ttl_ms: Keyword.get(opts, :ttl_s, @default_ttl_s) * 1000,
      retry_base_ms: Keyword.get(opts, :retry_base_s, @default_retry_base_s) * 1000,
      leagues: nil,
      fetched_at: nil,
      expires_at: nil,
      current: saved,
      current_source: if(saved, do: :saved, else: nil),
      task: nil,
      waiters: [],
      failures: 0,
      next_attempt_at: nil,
      timer: nil
    }

    if state.auto_refresh, do: send(self(), :refresh)
    {:ok, state}
  end

  @impl true
  def handle_call(:list, from, state) do
    cond do
      state.leagues != nil ->
        {:reply, {:ok, state.leagues}, state}

      state.task != nil ->
        {:noreply, %{state | waiters: [from | state.waiters]}}

      attempt_allowed?(state) ->
        {:noreply, state |> start_fetch() |> Map.update!(:waiters, &[from | &1])}

      true ->
        {:reply, {:error, :unavailable}, state}
    end
  end

  def handle_call(:current, _from, state), do: {:reply, state.current, state}

  def handle_call({:set_current, id}, _from, state) do
    cond do
      state.leagues == nil ->
        {:reply, {:error, :unavailable}, state}

      not Enum.any?(state.leagues, &(&1.id == id)) ->
        {:reply, {:error, :unknown_league}, state}

      true ->
        case Quicksilver.Settings.put(state.settings, "league", id) do
          :ok ->
            state = %{state | current: id, current_source: :user}
            PubSub.broadcast(state.pubsub, :league, :league_changed, id)
            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, {:settings, reason}}, state}
        end
    end
  end

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, maybe_fetch(state)}

  @impl true
  def handle_info(:refresh, state), do: {:noreply, maybe_fetch(%{state | timer: nil})}

  def handle_info({ref, result}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, handle_result(%{state | task: nil}, result)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{task: ref} = state),
    do: {:noreply, handle_result(%{state | task: nil}, {:error, {:task_crash, reason}})}

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Fetching ---------------------------------------------------------------

  defp maybe_fetch(state) do
    expired? = state.leagues == nil or now() >= state.expires_at

    if state.task == nil and expired? and attempt_allowed?(state),
      do: start_fetch(state),
      else: state
  end

  defp attempt_allowed?(%{next_attempt_at: nil}), do: true
  defp attempt_allowed?(%{next_attempt_at: t}), do: now() >= t

  defp start_fetch(state) do
    http = Keyword.put(state.http, :bucket, :trade_leagues)

    task =
      Task.Supervisor.async_nolink(state.task_sup, fn ->
        with {:ok, json, _resp} <- HTTP.get_json(Urls.trade_leagues(), http) do
          Parser.trade_leagues(json)
        end
      end)

    %{state | task: task.ref}
  end

  defp handle_result(state, {:ok, leagues}) do
    fetched_at = DateTime.utc_now()

    state = %{
      state
      | leagues: leagues,
        fetched_at: fetched_at,
        expires_at: now() + state.ttl_ms,
        failures: 0,
        next_attempt_at: nil
    }

    Health.report(state.health, :trade_leagues, status: :ok, cached_at: fetched_at, detail: nil)

    state
    |> reconcile_current()
    |> reply_waiters()
    |> schedule(state.ttl_ms)
  end

  defp handle_result(state, {:error, reason}) do
    failures = state.failures + 1
    retry_ms = min(state.retry_base_ms * Integer.pow(2, failures - 1), state.ttl_ms)
    detail = HTTP.describe_error(reason)

    Logger.warning(
      "leagues: fetch failed (#{inspect(reason)}); retry in #{div(retry_ms, 1000)} s"
    )

    if state.leagues,
      do: Health.report(state.health, :trade_leagues, status: :degraded, detail: detail),
      else: Health.report(state.health, :trade_leagues, status: :down, detail: detail)

    state = %{state | failures: failures, next_attempt_at: now() + retry_ms}

    state =
      if state.current == nil,
        do: change_current(state, @fallback_league, :fallback),
        else: state

    state |> reply_waiters() |> schedule(retry_ms)
  end

  defp reconcile_current(%{leagues: leagues, current: current} = state) do
    ids = Enum.map(leagues, & &1.id)
    [default | _] = ids

    cond do
      current in ids and state.current_source in [:saved, :user, :default] ->
        state

      state.current_source == :saved ->
        Logger.warning("leagues: saved league #{inspect(current)} isn't listed; using #{default}")
        change_current(state, default, :default)

      true ->
        change_current(state, default, :default)
    end
  end

  defp change_current(state, league, source) do
    if league != state.current,
      do: PubSub.broadcast(state.pubsub, :league, :league_changed, league)

    %{state | current: league, current_source: source}
  end

  defp reply_waiters(state) do
    reply = if state.leagues, do: {:ok, state.leagues}, else: {:error, :unavailable}
    Enum.each(state.waiters, &GenServer.reply(&1, reply))
    %{state | waiters: []}
  end

  defp schedule(%{auto_refresh: false} = state, _ms), do: state

  defp schedule(state, ms) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :refresh, ms)}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
