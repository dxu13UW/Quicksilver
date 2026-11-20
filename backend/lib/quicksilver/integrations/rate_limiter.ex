defmodule Quicksilver.Integrations.RateLimiter do
  @moduledoc """
  Header-driven request limiter for every external host (DATA_SOURCES.md
  "Client behaviour"). Limits are **learned from response headers**; there are
  no hard-coded rate numbers anywhere.

  ## Buckets and policies

  Callers name a **bucket** (an endpoint family such as `:trade_leagues` or
  `:poe_ninja`). Once a response carries `x-rate-limit-policy`, the bucket is
  mapped to that policy, and the hit history and restrictions are kept **per
  policy**, so two buckets that turn out to share a GGG policy also share its
  budget.

  * **No policy seen yet** (cold start, or a host that never sends the headers,
    like poe.ninja and the trade `data/*` endpoints): one request in flight per
    bucket.
  * **Policy known:** before each request every tier of every rule is checked.
    A request is sent only if it keeps the hits in each tier's window at or
    below `max`; otherwise it **waits in a FIFO queue** until the oldest
    relevant hit leaves the window (plus a small safety margin for clock and
    network skew). Requests are never dropped.
  * **Every response** updates the tiers and resyncs our hit history from the
    `-State` header (if the server counts more hits than we do, we add the
    difference as hits at "now", which is conservative).
  * **Active restriction or 429:** the whole policy pauses until the restriction
    ends. On 429 the pause is `max(Retry-After, active restriction)`; a 429
    without either (e.g. a CDN in front of poe.ninja) pauses the bucket for
    `:fallback_429_pause_s` (default 60 s). That is a back-off, not a rate.

  ## API

      {:ok, ticket} = RateLimiter.acquire(limiter, :trade_leagues)   # blocks while queued
      # ... send the request ...
      RateLimiter.release(limiter, ticket, {:response, status, headers})  # or :error

  `Quicksilver.Integrations.HTTP.get_json/2` does this for you. If the caller
  dies while holding a ticket, the slot is released automatically (monitor).

  ## Health

  With `health_sources: %{bucket => health_source}`, the limiter reports
  `rate_limit: %{policy, queued, restricted_until}` to `Quicksilver.Health`
  for buckets whose policy is known, whenever it changes.

  ## Options

  `:name`, `:clock` (0-arity fun returning monotonic ms; tests inject one),
  `:margin_ms` (default 500), `:fallback_429_pause_s` (default 60),
  `:health` (server, default `Quicksilver.Health`), `:health_sources`.
  """

  use GenServer
  require Logger

  alias Quicksilver.Integrations.RateLimiter.Headers

  @type bucket :: atom() | String.t()
  @type outcome :: {:response, non_neg_integer(), [{String.t(), String.t()}]} | :error

  # --- Public API -------------------------------------------------------------

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Waits (as long as needed) for a slot in `bucket`. Returns a ticket for `release/3`."
  @spec acquire(GenServer.server(), bucket()) :: {:ok, reference()}
  def acquire(server \\ __MODULE__, bucket),
    do: GenServer.call(server, {:acquire, bucket}, :infinity)

  @doc "Returns the slot and feeds the response headers back. Never blocks."
  @spec release(GenServer.server(), reference(), outcome()) :: :ok
  def release(server \\ __MODULE__, ticket, outcome),
    do: GenServer.cast(server, {:release, ticket, outcome})

  @doc """
  Current state of `bucket`: `%{policy: String.t() | nil, queued: n, in_flight: n,
  restricted_until: DateTime.t() | nil}`.
  """
  @spec status(GenServer.server(), bucket()) :: map()
  def status(server \\ __MODULE__, bucket), do: GenServer.call(server, {:status, bucket})

  @doc "Re-evaluates queues now (tests call this after advancing an injected clock)."
  @spec tick(GenServer.server()) :: :ok
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick)

  # --- GenServer --------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok,
     %{
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
       margin_ms: Keyword.get(opts, :margin_ms, 500),
       fallback_429_ms: Keyword.get(opts, :fallback_429_pause_s, 60) * 1000,
       health: Keyword.get(opts, :health, Quicksilver.Health),
       health_sources: Map.new(Keyword.get(opts, :health_sources, %{})),
       buckets: %{},
       policies: %{},
       tickets: %{},
       timer: nil,
       reported: %{}
     }}
  end

  @impl true
  def handle_call({:acquire, bucket}, from, state) do
    state =
      update_bucket(state, bucket, fn b -> %{b | queue: :queue.in(from, b.queue)} end)

    {:noreply, process(state)}
  end

  def handle_call({:status, bucket}, _from, state) do
    b = bucket(state, bucket)
    now = state.clock.()

    {:reply,
     %{
       policy: b.policy,
       queued: :queue.len(b.queue),
       in_flight: b.in_flight,
       restricted_until: to_datetime(restricted_until(state, b), now)
     }, state}
  end

  def handle_call(:tick, _from, state), do: {:reply, :ok, process(state)}

  @impl true
  def handle_cast({:release, ticket, outcome}, state) do
    case Map.pop(state.tickets, ticket) do
      {nil, _} ->
        {:noreply, state}

      {{bucket, mon}, tickets} ->
        Process.demonitor(mon, [:flush])
        state = %{state | tickets: tickets}
        state = update_bucket(state, bucket, &%{&1 | in_flight: max(&1.in_flight - 1, 0)})
        {:noreply, state |> learn(bucket, outcome) |> process()}
    end
  end

  @impl true
  def handle_info(:wake, state), do: {:noreply, process(%{state | timer: nil})}

  def handle_info({:DOWN, mon, :process, _pid, _}, state) do
    case Enum.find(state.tickets, fn {_t, {_b, m}} -> m == mon end) do
      nil ->
        {:noreply, state}

      {ticket, {bucket, _}} ->
        state = %{state | tickets: Map.delete(state.tickets, ticket)}
        state = update_bucket(state, bucket, &%{&1 | in_flight: max(&1.in_flight - 1, 0)})
        {:noreply, process(state)}
    end
  end

  # --- Learning from responses ------------------------------------------------

  defp learn(state, _bucket, :error), do: state

  defp learn(state, bucket, {:response, status, headers}) do
    now = state.clock.()
    parsed = Headers.parse(headers)

    state =
      case parsed do
        nil -> state
        %{policy: name, rules: rules} -> apply_policy(state, bucket, name, rules, now)
      end

    if status == 429, do: apply_429(state, bucket, parsed, headers, now), else: state
  end

  defp apply_policy(state, bucket, name, rules, now) do
    old = Map.get(state.policies, name, %{tiers: [], hits: [], restricted_until: nil})

    tiers =
      for r <- rules, t <- r.tiers, do: {t.max, t.period_s * 1000}

    # Tiers can change at any time (GGG: limits are dynamic). Keep enough
    # history for the longest window.
    hits = prune(old.hits, now, max_period(tiers))

    hits =
      Enum.reduce(rules, hits, fn r, hits ->
        Enum.reduce(r.state, hits, fn s, hits ->
          ours = count_since(hits, now - s.period_s * 1000)
          if s.current > ours, do: List.duplicate(now, s.current - ours) ++ hits, else: hits
        end)
      end)

    active_ms =
      for(r <- rules, s <- r.state, do: s.active_s * 1000) |> Enum.max(fn -> 0 end)

    restricted_until =
      if active_ms > 0,
        do: max_or(old.restricted_until, now + active_ms),
        else: old.restricted_until

    if active_ms > 0,
      do: Logger.warning("rate limit: policy #{name} is restricted for #{div(active_ms, 1000)} s")

    policy = %{tiers: tiers, hits: hits, restricted_until: restricted_until}
    state = put_in(state.policies[name], policy)
    update_bucket(state, bucket, &%{&1 | policy: name})
  end

  defp apply_429(state, bucket, parsed, headers, now) do
    retry_ms = (Headers.retry_after_s(headers) || 0) * 1000

    active_ms =
      case parsed do
        nil ->
          0

        %{rules: rules} ->
          for(r <- rules, s <- r.state, do: s.active_s * 1000) |> Enum.max(fn -> 0 end)
      end

    pause_ms =
      case max(retry_ms, active_ms) do
        0 -> state.fallback_429_ms
        ms -> ms
      end

    Logger.warning("rate limit: HTTP 429 on #{inspect(bucket)}; pausing #{div(pause_ms, 1000)} s")
    until = now + pause_ms

    case bucket(state, bucket).policy do
      nil ->
        update_bucket(
          state,
          bucket,
          &%{&1 | restricted_until: max_or(&1.restricted_until, until)}
        )

      name ->
        update_in(
          state.policies[name],
          &%{&1 | restricted_until: max_or(&1.restricted_until, until)}
        )
    end
  end

  # --- Dispatch ---------------------------------------------------------------

  defp process(state) do
    now = state.clock.()

    {state, wakes} =
      Enum.reduce(Map.keys(state.buckets), {state, []}, fn bucket, {state, wakes} ->
        {state, wake} = drain(state, bucket, now)
        {state, if(wake, do: [wake | wakes], else: wakes)}
      end)

    state |> schedule(wakes, now) |> report_health(now)
  end

  # Grants queued requests in `bucket` while allowed. Returns the time to wake
  # up at if the queue is blocked on time (nil if empty or blocked on in-flight).
  defp drain(state, bucket, now) do
    b = bucket(state, bucket)

    case :queue.out(b.queue) do
      {:empty, _} ->
        {state, nil}

      {{:value, from}, rest} ->
        case check(state, b, now) do
          :ok ->
            state = grant(state, bucket, from, rest, now)
            drain(state, bucket, now)

          :busy ->
            {state, nil}

          {:wait_until, t} ->
            {state, t}
        end
    end
  end

  defp check(state, b, now) do
    case restricted_until(state, b) do
      t when is_integer(t) and t > now ->
        {:wait_until, t}

      _ ->
        case b.policy && state.policies[b.policy] do
          nil -> if b.in_flight == 0, do: :ok, else: :busy
          policy -> check_tiers(policy, now, state.margin_ms)
        end
    end
  end

  defp check_tiers(%{tiers: tiers, hits: hits}, now, margin) do
    waits =
      for {max, period} <- tiers,
          in_window = Enum.take_while(hits, &(&1 > now - period)),
          length(in_window) >= max do
        # hits are newest first; after the hit at index max-1 leaves the window,
        # one more request fits.
        Enum.at(in_window, max - 1) + period + margin
      end

    case waits do
      [] -> :ok
      _ -> {:wait_until, Enum.max(waits)}
    end
  end

  defp grant(state, bucket, {pid, _} = from, rest, now) do
    ticket = make_ref()
    mon = Process.monitor(pid)
    GenServer.reply(from, {:ok, ticket})

    state = %{state | tickets: Map.put(state.tickets, ticket, {bucket, mon})}
    state = update_bucket(state, bucket, &%{&1 | queue: rest, in_flight: &1.in_flight + 1})

    case bucket(state, bucket).policy do
      nil ->
        state

      name ->
        update_in(state.policies[name], fn p ->
          %{p | hits: [now | prune(p.hits, now, max_period(p.tiers))]}
        end)
    end
  end

  defp schedule(state, [], _now), do: cancel_timer(state)

  defp schedule(state, wakes, now) do
    state = cancel_timer(state)
    delay = max(Enum.min(wakes) - now, 1)
    %{state | timer: Process.send_after(self(), :wake, delay)}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: t} = state) do
    Process.cancel_timer(t)
    %{state | timer: nil}
  end

  # --- Health -----------------------------------------------------------------

  defp report_health(state, now) do
    Enum.reduce(state.health_sources, state, fn {bucket, source}, state ->
      b = bucket(state, bucket)

      if b.policy do
        rl = %{
          policy: b.policy,
          queued: :queue.len(b.queue),
          restricted_until: to_datetime(restricted_until(state, b), now)
        }

        if Map.get(state.reported, bucket) == rl do
          state
        else
          Quicksilver.Health.report(state.health, source, rate_limit: rl)
          put_in(state.reported[bucket], rl)
        end
      else
        state
      end
    end)
  end

  # --- Helpers ----------------------------------------------------------------

  defp bucket(state, bucket),
    do:
      Map.get(state.buckets, bucket, %{
        policy: nil,
        queue: :queue.new(),
        in_flight: 0,
        restricted_until: nil
      })

  defp update_bucket(state, bucket, fun),
    do: put_in(state.buckets[bucket], fun.(bucket(state, bucket)))

  defp restricted_until(state, b) do
    policy_until = b.policy && get_in(state.policies, [b.policy, :restricted_until])
    max_or(b.restricted_until, policy_until)
  end

  defp to_datetime(nil, _now), do: nil
  defp to_datetime(t, now) when t <= now, do: nil
  defp to_datetime(t, now), do: DateTime.add(DateTime.utc_now(), t - now, :millisecond)

  defp prune(hits, now, period), do: Enum.take_while(hits, &(&1 > now - period))

  defp count_since(hits, since), do: Enum.count(hits, &(&1 > since))

  defp max_period([]), do: 0
  defp max_period(tiers), do: tiers |> Enum.map(&elem(&1, 1)) |> Enum.max()

  defp max_or(nil, b), do: b
  defp max_or(a, nil), do: a
  defp max_or(a, b), do: max(a, b)
end
