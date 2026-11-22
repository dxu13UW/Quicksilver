defmodule Quicksilver.Gateway.Handlers.Dashboard do
  @moduledoc """
  PROTOCOL.md "Dashboard": `leagues.list`, `league.set`, `rates.subscribe`,
  `rates.unsubscribe`, the `rates.update` pushes and the rates error push
  (DASH-1, DASH-2).

  Data comes from the connection's `Quicksilver.Gateway.DataSource`
  (`conn.opts.data_source`; in production, `Quicksilver.Integrations`).

  ## Message flow

    * `leagues.list` → (task) list the leagues, waiting for the first fetch on a
      cold cache, then read the current league → `leagues.result`
      `{leagues: [{id, text}], current}`.
    * `league.set {league}` → (task) make sure the list is loaded, then select
      and save the league → `league.changed {league}`. If the list can't be
      fetched → `upstream_unavailable`, nothing saved. The data source then
      broadcasts the new league's rates, which become a `rates.update` push if
      this connection is subscribed (PROTOCOL: "a fresh `rates.update` push
      follows").
    * `rates.subscribe` → subscribe this process to rates and league broadcasts
      at once (so no refresh is missed), then (task) read the rates →
      `rates.update` echoing the id, or error `upstream_unavailable`; the
      subscription stays active either way.
    * `rates.unsubscribe` → unsubscribe from rates → `rates.unsubscribed {}`.
      Idempotent.
    * rates broadcast → `rates.update` push (id `null`) while subscribed.
    * league broadcast (every connection gets these: `join/1` subscribes at
      the handshake) → `league.changed` push (id `null`) unless this client
      already knows that league: the one in its `welcome`, its own `league.set`
      reply, or an earlier push (PROTOCOL "`league.changed` push"). So a
      client's own `league.set` gets only the reply; other clients get the push.
    * league broadcast while subscribed to rates → (task) read the rates for the now-current
      league. If there are none (`:league_not_covered`, `:unavailable`,
      `:no_league`), push the **rates error**: `error` with id `null` and payload
      `{code: "upstream_unavailable", message, topic: "rates", league}`. If
      there are rates, nothing extra is sent: the data source's own broadcast
      delivers them. The error is dropped if the league changed again meanwhile,
      and isn't repeated for the same league until a `rates.update` has been
      sent in between (no duplicates).

  ## Ordering

  PROTOCOL promises the `rates.update` reply to `rates.subscribe` comes before
  any push, and that whatever follows `league.set` (a `rates.update` or the
  rates error) comes after `league.changed`. A `league.changed` push goes out
  as soon as the league broadcast arrives, and the rates check only starts
  then, so it always precedes the rates push for that league. A broadcast or league check can
  finish before the request's own task does, so while a `rates.subscribe` or
  `league.set` is in flight, rates pushes are held (only the newest is kept: it
  supersedes older ones) and sent right after the reply. A held push is dropped
  if it is a `rates.update` identical to the `rates.subscribe` reply, or if it
  is for another league than the one `league.set` just selected.

  While a `league.set` is in flight, `league.changed` pushes are held too (the
  newest only), so this client's own change, whose broadcast can beat the
  task's answer, isn't pushed in addition to the reply. After the reply the
  held push is sent only if it names a league other than the one just set.

  ## Error mapping (PROTOCOL "error")

  | data source | code |
  |---|---|
  | `:unknown_league` | `unknown_league` |
  | `:unavailable`, `:no_league`, `:league_not_covered` | `upstream_unavailable` |
  | `{:settings, _}`, a crashed task, anything unexpected | `internal` (details logged) |

  A missing or empty `league` in `league.set` is `bad_request`.

  ## Per-connection state (`conn.assigns`)

    * `:rates_subscribed`: whether rates pushes are wanted.
    * `:rates_in_flight`: number of `rates.subscribe` / `league.set` jobs running.
    * `:rates_held`: the newest rates push held back while that number is > 0:
      `{:update, rates}` or `{:error, league, message}`.
    * `:rates_league`: the league of the newest league broadcast seen.
    * `:rates_error_league`: the league of the last rates error sent (as a
      push, or as the `rates.subscribe` error reply), cleared by the next
      `rates.update` (duplicate suppression).
    * `:league_known`: the league this client was last told about.
    * `:league_set_in_flight`: number of `league.set` jobs running.
    * `:league_held`: the newest league broadcast held back while that number
      is > 0.
  """

  @behaviour Quicksilver.Gateway.Handler

  require Logger

  alias Quicksilver.Gateway.Connection

  @row_fields [:id, :name, :chaos, :divine, :change_7d, :volume_chaos]
  @league_check "rates.league_check"

  # --- Connection ------------------------------------------------------------------

  @doc """
  Called by the socket on a valid `hello`, before it reads the active league
  for `welcome`: subscribes the connection to league broadcasts, so a change
  between that read and the welcome is still pushed (after the welcome). If
  the subscription fails (PubSub restarting), the connection works without
  `league.changed` pushes; that is logged.
  """
  @spec join(Connection.t()) :: Connection.t()
  def join(conn) do
    {source, arg} = conn.opts.data_source
    :ok = source.subscribe(arg, :league)
    conn
  rescue
    exception ->
      Logger.warning(
        "gateway: no league pushes for this connection: " <> Exception.message(exception)
      )

      conn
  catch
    :exit, reason ->
      Logger.warning("gateway: no league pushes for this connection: #{inspect(reason)}")
      conn
  end

  @doc "Records the league sent in `welcome` (`nil` if none) as known to the client."
  @spec welcomed(Connection.t(), String.t() | nil) :: Connection.t()
  def welcomed(conn, league), do: put(conn, :league_known, league)

  # --- Requests -------------------------------------------------------------------

  @impl true
  def handle_message("leagues.list", _payload, conn) do
    {source, arg} = conn.opts.data_source
    timeout = conn.opts.upstream_timeout_ms

    job = fn ->
      with {:ok, leagues} <- source.list_leagues(arg, timeout) do
        {:ok, leagues, source.current_league(arg)}
      end
    end

    {:async, job, conn}
  end

  def handle_message("league.set", %{"league" => league}, conn)
      when is_binary(league) and league != "" do
    {source, arg} = conn.opts.data_source
    timeout = conn.opts.upstream_timeout_ms

    # set_league/2 answers :unavailable while the list hasn't loaded yet; on a
    # cold start, wait for it like leagues.list does, so the client gets a real
    # unknown_league / league.changed instead.
    job = fn ->
      with {:ok, _leagues} <- source.list_leagues(arg, timeout),
           :ok <- source.set_league(arg, league) do
        {:ok, league}
      else
        error -> {:failed, league, error}
      end
    end

    conn = put(conn, :league_set_in_flight, get(conn, :league_set_in_flight, 0) + 1)
    {:async, job, hold(conn)}
  end

  def handle_message("league.set", _payload, conn),
    do: {:error, :bad_request, ~s(league.set needs a non-empty string "league".), conn}

  def handle_message("rates.subscribe", _payload, conn) do
    {source, arg} = conn.opts.data_source
    timeout = conn.opts.upstream_timeout_ms

    # Subscribe before reading, so a refresh between the read and the reply
    # can't be missed (it is held and sent after the reply).
    :ok = source.subscribe(arg, :rates)
    conn = conn |> put(:rates_subscribed, true) |> hold()

    # The league read after the answer is the one an error is about: it lets a
    # rates error push for that same league be suppressed (it would repeat
    # this reply).
    job = fn ->
      result = source.rates(arg, timeout: timeout)
      {result, source.current_league(arg)}
    end

    {:async, job, conn}
  end

  def handle_message("rates.unsubscribe", _payload, conn) do
    {source, arg} = conn.opts.data_source
    # League broadcasts stay: every connection gets league.changed pushes.
    :ok = source.unsubscribe(arg, :rates)

    conn =
      conn
      |> put(:rates_subscribed, false)
      |> put(:rates_held, nil)
      |> put(:rates_error_league, nil)

    {:reply, "rates.unsubscribed", %{}, conn}
  end

  # --- Task results ---------------------------------------------------------------

  @impl true
  def handle_async("leagues.list", {:ok, {:ok, leagues, current}}, conn) do
    payload = %{leagues: Enum.map(leagues, &%{id: &1.id, text: &1.text}), current: current}
    {:reply, "leagues.result", payload, conn}
  end

  def handle_async("leagues.list", outcome, conn) do
    {code, message} = failure("leagues.list", outcome, nil)
    {:error, code, message, conn}
  end

  def handle_async("league.set", outcome, conn) do
    conn = release(conn)
    conn = put(conn, :league_set_in_flight, max(get(conn, :league_set_in_flight, 0) - 1, 0))

    case outcome do
      {:ok, {:ok, league}} ->
        conn = drop_held_unless(conn, &(held_league(&1) == league))
        conn = put(conn, :league_known, league)
        flush({:reply, "league.changed", %{league: league}}, conn)

      {:ok, {:failed, league, error}} ->
        {code, message} = failure("league.set", {:ok, error}, league)
        flush({:error, code, message}, conn)

      outcome ->
        {code, message} = failure("league.set", outcome, nil)
        flush({:error, code, message}, conn)
    end
  end

  def handle_async("rates.subscribe", outcome, conn) do
    conn = release(conn)

    case outcome do
      {:ok, {{:ok, rates}, _league}} ->
        conn = drop_held_unless(conn, &(&1 != {:update, rates}))
        conn = put(conn, :rates_error_league, nil)
        flush({:reply, "rates.update", rates_payload(rates)}, conn)

      {:ok, {{:error, _} = error, league}} ->
        # This reply already tells the client there are no rates for `league`.
        conn = drop_held_unless(conn, &(not match?({:error, ^league, _}, &1)))
        conn = if league, do: put(conn, :rates_error_league, league), else: conn
        {code, message} = failure("rates.subscribe", {:ok, error}, nil)
        flush({:error, code, message}, conn)

      outcome ->
        {code, message} = failure("rates.subscribe", outcome, nil)
        flush({:error, code, message}, conn)
    end
  end

  # The league check started on a league broadcast (see the moduledoc).
  def handle_async(@league_check, {:ok, {league, {:error, reason}}}, conn)
      when reason in [:league_not_covered, :unavailable, :no_league] do
    if get(conn, :rates_league, nil) == league do
      {_code, message} = failure(@league_check, {:ok, {:error, reason}}, league)
      {pushes, conn} = emit({:error, league, message}, conn)
      {:frames, pushes, conn}
    else
      # The league changed again meanwhile; a newer check covers it.
      {:noreply, conn}
    end
  end

  def handle_async(@league_check, {:ok, {_league, {:ok, _rates}}}, conn), do: {:noreply, conn}

  def handle_async(@league_check, outcome, conn) do
    Logger.error("gateway: rates check after a league change failed: #{inspect(outcome)}")
    {:noreply, conn}
  end

  # --- Broadcasts -------------------------------------------------------------------

  @impl true
  def handle_info({Quicksilver.Integrations, :rates, rates}, conn) do
    case emit({:update, rates}, conn) do
      {[], conn} -> {:ok, conn}
      {[{:push, type, payload}], conn} -> {:push, [{type, payload}], conn}
    end
  end

  def handle_info({Quicksilver.Integrations, :league_changed, league}, conn) do
    {pushes, conn} = emit_league(league, conn)

    if get(conn, :rates_subscribed, false) do
      {source, arg} = conn.opts.data_source
      timeout = conn.opts.upstream_timeout_ms
      # rates/2 for the current league: it waits for the new league's first
      # fetch if nothing is cached, and starts one if needed. Started after the
      # league.changed push, so its error can only come later.
      job = fn -> {league, source.rates(arg, timeout: timeout)} end
      {:async, @league_check, job, pushes, put(conn, :rates_league, league)}
    else
      {:frames, pushes, conn}
    end
  end

  def handle_info(_message, conn), do: {:ok, conn}

  # --- Payloads -----------------------------------------------------------------------

  @doc "Turns `Quicksilver.Integrations.rates/1` data into a `rates.update` payload."
  @spec rates_payload(map()) :: map()
  def rates_payload(rates) do
    %{
      league: rates.league,
      source: rates.source,
      fetched_at: Quicksilver.Time.iso8601_ms(rates.fetched_at),
      stale: rates.stale,
      divine_chaos: rates.divine_chaos,
      rates: Enum.map(rates.rates, &Map.take(&1, @row_fields))
    }
  end

  # {code, message} for a failed job. `message` is plain language for display;
  # the client acts on `code` only.
  defp failure(_type, {:ok, {:error, :unknown_league}}, league),
    do: {:unknown_league, "League '#{league}' isn't available."}

  defp failure("leagues.list", {:ok, {:error, :unavailable}}, _),
    do: {:upstream_unavailable, "The league list can't be fetched right now."}

  defp failure("league.set", {:ok, {:error, :unavailable}}, _),
    do:
      {:upstream_unavailable,
       "The league list can't be fetched right now, so the league can't be changed."}

  defp failure(_type, {:ok, {:error, :unavailable}}, _),
    do: {:upstream_unavailable, "poe.ninja can't be reached and there are no saved rates yet."}

  defp failure(_type, {:ok, {:error, :no_league}}, _),
    do: {:upstream_unavailable, "No league is known yet, so there are no rates to show."}

  defp failure(_type, {:ok, {:error, :league_not_covered}}, _),
    do: {:upstream_unavailable, "poe.ninja has no prices for this league."}

  defp failure(type, outcome, _league) do
    Logger.error("gateway: #{type} failed: #{inspect(outcome)}")
    {:internal, "Something went wrong in the backend."}
  end

  # --- League pushes ----------------------------------------------------------------------

  defp emit_league(league, conn) do
    if get(conn, :league_set_in_flight, 0) > 0,
      do: {[], put(conn, :league_held, league)},
      else: send_league(league, conn)
  end

  defp send_league(league, conn) do
    if get(conn, :league_known, nil) == league,
      do: {[], conn},
      else: {[{:push, "league.changed", %{league: league}}], put(conn, :league_known, league)}
  end

  # --- Rates pushes: hold, flush, de-duplicate ------------------------------------------

  # Sends a rates push now, holds it while a request it must follow is in
  # flight, or drops it when not subscribed. Returns {frames, conn}.
  defp emit(item, conn) do
    cond do
      not get(conn, :rates_subscribed, false) -> {[], conn}
      get(conn, :rates_in_flight, 0) > 0 -> {[], put(conn, :rates_held, item)}
      true -> send_item(item, conn)
    end
  end

  defp send_item({:update, rates}, conn),
    do: {[{:push, "rates.update", rates_payload(rates)}], put(conn, :rates_error_league, nil)}

  defp send_item({:error, league, message}, conn) do
    if get(conn, :rates_error_league, nil) == league do
      {[], conn}
    else
      frame = {:push_error, :upstream_unavailable, message, %{topic: "rates", league: league}}
      {[frame], put(conn, :rates_error_league, league)}
    end
  end

  defp held_league({:update, rates}), do: rates.league
  defp held_league({:error, league, _message}), do: league

  defp hold(conn), do: put(conn, :rates_in_flight, get(conn, :rates_in_flight, 0) + 1)

  defp release(conn),
    do: put(conn, :rates_in_flight, max(get(conn, :rates_in_flight, 0) - 1, 0))

  defp drop_held_unless(conn, keep?) do
    case get(conn, :rates_held, nil) do
      nil -> conn
      held -> if keep?.(held), do: conn, else: put(conn, :rates_held, nil)
    end
  end

  # The reply, then the held pushes once nothing that must precede them is in
  # flight any more: the league push first, then the rates push.
  defp flush(reply, conn) do
    {league_pushes, conn} = flush_league(conn)
    {rates_pushes, conn} = flush_rates(conn)
    {:frames, [reply | league_pushes ++ rates_pushes], conn}
  end

  defp flush_league(conn) do
    held = get(conn, :league_held, nil)

    if held != nil and get(conn, :league_set_in_flight, 0) == 0,
      do: send_league(held, put(conn, :league_held, nil)),
      else: {[], conn}
  end

  defp flush_rates(conn) do
    held = get(conn, :rates_held, nil)

    cond do
      held == nil or get(conn, :rates_in_flight, 0) > 0 -> {[], conn}
      get(conn, :rates_subscribed, false) -> send_item(held, put(conn, :rates_held, nil))
      true -> {[], put(conn, :rates_held, nil)}
    end
  end

  defp get(%Connection{assigns: assigns}, key, default), do: Map.get(assigns, key, default)

  defp put(%Connection{} = conn, key, value),
    do: %{conn | assigns: Map.put(conn.assigns, key, value)}
end
