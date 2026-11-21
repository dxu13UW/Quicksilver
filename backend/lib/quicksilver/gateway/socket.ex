defmodule Quicksilver.Gateway.Socket do
  @moduledoc """
  One WebSocket connection on `/ws` (`WebSock` behaviour, run by Bandit).

  Lifecycle (PROTOCOL.md "Connection"):

    1. On connect a hello timer starts (`hello_timeout_ms`, 5 s by default).
    2. The first frame must be a valid `hello`. Anything else, or no frame before
       the timer fires, gets error `unauthorized` and the connection is closed.
       A bad `hello` gets `protocol_mismatch`, `bad_request` or `unauthorized`
       (see `Quicksilver.Gateway.Handshake`) and is closed too.
    3. On success the server sends `welcome` (echoing the hello id), then one
       `health` push right away, then a `health` push every `health_interval_ms`.
    4. After that, each frame is decoded (`bad_json` on failure, connection stays
       open) and routed through `Quicksilver.Gateway.Routes`. Unknown types get
       `unknown_type` and the connection stays open.

  Handshake failures close with WebSocket status 1008 (policy violation).
  PROTOCOL.md does not specify a close code; clients act on the `error` code.

  Each connection is its own process under Bandit's connection supervisor, so a
  crash here only drops this one client. Handler exceptions are caught and
  answered with `internal`, so they don't even drop the connection.

  Slow work (anything that may wait on a data source) runs in tasks under the
  gateway's `Task.Supervisor` (`Quicksilver.Gateway.Handler` `{:async, ...}`),
  so this process never blocks: health pushes, other requests and rates pushes
  keep flowing while a request waits for the network. In-flight jobs are
  tracked in `conn.tasks` and killed when the connection ends.
  """

  @behaviour WebSock

  require Logger

  alias Quicksilver.Gateway.{Connection, Envelope, Handshake, Routes}
  alias Quicksilver.{Health, Settings}

  @policy_violation 1008
  @welcome_league_wait_ms 500

  @impl WebSock
  def init(opts) do
    timer = Process.send_after(self(), :hello_timeout, opts.hello_timeout_ms)
    {:ok, %Connection{opts: opts, hello_timer: timer}}
  end

  # --- Incoming frames ----------------------------------------------------------

  @impl WebSock
  def handle_in({frame, opcode: :text}, %Connection{phase: :awaiting_hello} = conn) do
    case Envelope.decode(frame) do
      {:ok, %{type: "hello", id: id, payload: payload}} ->
        handshake(id, payload, conn)

      {:ok, %{type: type, id: id}} ->
        Logger.info("gateway: #{inspect(type)} sent before hello; closing")
        reject(:unauthorized, "The first message must be hello.", id, conn)

      {:error, _reason, id} ->
        Logger.info("gateway: malformed frame before hello; closing")
        reject(:unauthorized, "The first message must be hello.", id, conn)
    end
  end

  def handle_in({frame, opcode: :text}, %Connection{phase: :ready} = conn) do
    case Envelope.decode(frame) do
      {:ok, %{type: "hello", id: id}} ->
        push_error(:bad_request, "The handshake is already complete.", id, conn)

      {:ok, %{type: type, id: id, payload: payload}} ->
        dispatch(type, id, payload, conn)

      {:error, message, id} ->
        push_error(:bad_json, message, id, conn)
    end
  end

  # PROTOCOL.md: text frames carry one JSON object each. Binary frames are not part
  # of v1, so they are treated like any other malformed frame.
  def handle_in({_data, opcode: :binary}, %Connection{phase: :awaiting_hello} = conn),
    do: reject(:unauthorized, "The first message must be hello.", nil, conn)

  def handle_in({_data, opcode: :binary}, conn),
    do: push_error(:bad_json, "Messages must be sent as text frames.", nil, conn)

  # --- Timers and other process messages ----------------------------------------

  @impl WebSock
  def handle_info(:hello_timeout, %Connection{phase: :awaiting_hello} = conn) do
    seconds = conn.opts.hello_timeout_ms / 1000
    Logger.info("gateway: no hello within #{seconds} s; closing")
    reject(:unauthorized, "No hello was received in time.", nil, conn)
  end

  def handle_info(:health_tick, %Connection{phase: :ready} = conn) do
    conn = schedule_health(conn)

    case health_frame(conn) do
      nil -> {:ok, conn}
      frame -> {:push, [frame], conn}
    end
  end

  # An async handler job finished: Task.Supervisor.async_nolink replies with
  # {monitor_ref, value}. Drop the monitor (and a DOWN that may already be queued).
  def handle_info({ref, value}, %Connection{tasks: tasks} = conn)
      when is_reference(ref) and is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    finish_task(ref, {:ok, value}, conn)
  end

  # An async handler job crashed (or was killed) before replying.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %Connection{tasks: tasks} = conn)
      when is_map_key(tasks, ref) do
    finish_task(ref, {:exit, reason}, conn)
  end

  # Data-source broadcasts (e.g. rates refreshed) go to the handler that owns
  # the subscription; Routes.info_handler/1 names it.
  def handle_info(message, %Connection{phase: :ready} = conn) do
    case Routes.info_handler(message) do
      {:ok, handler} -> run_info(handler, message, conn)
      :error -> {:ok, conn}
    end
  end

  # A stale :hello_timeout after the handshake, or anything unexpected.
  def handle_info(_message, conn), do: {:ok, conn}

  # Subscriptions (Registry entries) disappear on their own when this process
  # exits. Async jobs still in flight are killed: their answers have nowhere to
  # go. (If this process is killed outright, terminate/2 doesn't run; the jobs
  # then end by themselves within :upstream_timeout_ms and their replies are
  # dropped by the VM.)
  @impl WebSock
  def terminate(_reason, conn) do
    for {_ref, {pid, _handler, _type, _id}} <- conn.tasks, do: Process.exit(pid, :kill)
    :ok
  end

  # --- Handshake ------------------------------------------------------------------

  defp handshake(id, payload, conn) do
    case Handshake.check(payload, conn.opts) do
      {:ok, %{client_version: client_version}} ->
        cancel_timer(conn.hello_timer)
        conn = %{conn | phase: :ready, hello_timer: nil, client_version: client_version}
        Logger.info("gateway: client #{client_version} connected")

        welcome = {:text, Envelope.encode("welcome", id, welcome_payload(conn))}
        conn = schedule_health(conn)
        {:push, Enum.reject([welcome, health_frame(conn)], &is_nil/1), conn}

      {:error, code, message, extra} ->
        Logger.info("gateway: hello rejected (#{code}); closing")
        reject(code, message, id, conn, extra)
    end
  end

  defp welcome_payload(conn) do
    settings = conn.opts.settings

    %{
      server_version: Quicksilver.version(),
      protocol_version: Quicksilver.protocol_version(),
      league: active_league(conn),
      features: %{trade_api_enabled: setting(settings, "trade_api_enabled", true) != false},
      health_interval_s: interval_seconds(conn.opts.health_interval_ms)
    }
  end

  # PROTOCOL `welcome.league`: the active league (same as leagues.result.current).
  # The data source answers from memory (it never waits on the network for
  # this), but the call is still bounded so a busy or restarting server can't
  # delay the handshake: after @welcome_league_wait_ms the welcome goes out with
  # null, which PROTOCOL allows ("no league yet").
  defp active_league(conn) do
    {source, arg} = conn.opts.data_source
    task = Task.Supervisor.async_nolink(conn.opts.task_sup, fn -> source.current_league(arg) end)

    case Task.yield(task, @welcome_league_wait_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, league} when is_binary(league) and league != "" ->
        league

      {:ok, _none} ->
        nil

      other ->
        Logger.warning("gateway: active league unavailable for welcome: #{inspect(other)}")
        nil
    end
  catch
    :exit, reason ->
      Logger.warning("gateway: active league unavailable for welcome: #{inspect(reason)}")
      nil
  end

  # If the settings process is restarting, answer with defaults rather than drop
  # the handshake.
  defp setting(settings, key, default) do
    Settings.get(settings, key, default)
  catch
    :exit, reason ->
      Logger.warning(
        "gateway: settings unavailable, using default for #{key}: #{inspect(reason)}"
      )

      default
  end

  # Whole seconds go out as an integer (the production value is 5). Sub-second
  # intervals only exist in tests and go out as a float.
  defp interval_seconds(ms) when rem(ms, 1000) == 0, do: div(ms, 1000)
  defp interval_seconds(ms), do: ms / 1000

  # --- Routing --------------------------------------------------------------------

  defp dispatch(type, id, payload, conn) do
    case Routes.fetch(type) do
      {:ok, handler} ->
        run_handler(handler, type, id, payload, conn)

      :error ->
        push_error(:unknown_type, "Unknown message type #{inspect(type)}.", id, conn)
    end
  end

  defp run_handler(handler, type, id, payload, conn) do
    guarded(type, id, conn, fn ->
      case handler.handle_message(type, payload, conn) do
        {:async, fun, %Connection{} = conn} when is_function(fun, 0) ->
          start_task(handler, type, id, fun, conn)

        result ->
          send_result(handler, result, id)
      end
    end)
  end

  # Runs `fun` in a task so a slow data source never blocks this process: the
  # mailbox keeps being served (health ticks, other requests, pushes) while the
  # task waits. The result comes back as a process message (handle_info above).
  # Tasks run under the gateway's Task.Supervisor (async_nolink), so a crashing
  # job is reported to us as :DOWN instead of taking the connection down.
  defp start_task(handler, type, id, fun, conn) do
    task = Task.Supervisor.async_nolink(conn.opts.task_sup, fun)
    {:ok, %{conn | tasks: Map.put(conn.tasks, task.ref, {task.pid, handler, type, id})}}
  catch
    # The task supervisor is restarting: let the handler settle its state as if
    # the job had crashed.
    :exit, reason ->
      send_result(handler, handler.handle_async(type, {:exit, reason}, conn), id)
  end

  defp finish_task(ref, outcome, conn) do
    {{_pid, handler, type, id}, tasks} = Map.pop(conn.tasks, ref)
    conn = %{conn | tasks: tasks}

    guarded(type, id, conn, fn ->
      send_result(handler, handler.handle_async(type, outcome, conn), id)
    end)
  end

  defp run_info(handler, message, conn) do
    case handler.handle_info(message, conn) do
      # A job not tied to a request: its result has id null.
      {:async, type, fun, %Connection{} = conn} when is_function(fun, 0) ->
        start_task(handler, type, nil, fun, conn)

      {:push, [], %Connection{} = conn} ->
        {:ok, conn}

      {:push, pushes, %Connection{} = conn} ->
        {:push, Enum.map(pushes, fn {t, p} -> {:text, Envelope.encode(t, nil, p)} end), conn}

      {:ok, %Connection{} = conn} ->
        {:ok, conn}
    end
  rescue
    exception ->
      Logger.error(
        "gateway: #{inspect(handler)} failed on a process message: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:ok, conn}
  end

  defp send_result(handler, result, id) do
    case result do
      {:reply, reply_type, reply_payload, %Connection{} = conn} ->
        {:push, [{:text, Envelope.encode(reply_type, id, reply_payload)}], conn}

      {:error, code, message, %Connection{} = conn} ->
        push_error(code, message, id, conn)

      {:frames, [], %Connection{} = conn} ->
        {:ok, conn}

      {:frames, frames, %Connection{} = conn} when is_list(frames) ->
        {:push, Enum.map(frames, &encode_frame(&1, id)), conn}

      {:noreply, %Connection{} = conn} ->
        {:ok, conn}

      other ->
        raise "handler #{inspect(handler)} returned an invalid result: #{inspect(other)}"
    end
  end

  defp encode_frame({:reply, type, payload}, id), do: {:text, Envelope.encode(type, id, payload)}
  defp encode_frame({:error, code, message}, id), do: {:text, Envelope.error(code, message, id)}

  defp encode_frame({:push_error, code, message, extra}, _id),
    do: {:text, Envelope.error(code, message, nil, extra)}

  defp encode_frame({:push, type, payload}, _id), do: {:text, Envelope.encode(type, nil, payload)}

  # A bug in a handler is answered with `internal` and the connection stays
  # open. Exits (a server the handler called is down) are treated the same.
  defp guarded(type, id, conn, fun) do
    fun.()
  rescue
    exception ->
      # NFR: bug details go to the backend log, never to the client.
      Logger.error(
        "gateway: handler for #{inspect(type)} crashed: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      push_error(:internal, "Something went wrong in the backend.", id, conn)
  catch
    :exit, reason ->
      Logger.error("gateway: handler for #{inspect(type)} exited: #{inspect(reason)}")
      push_error(:internal, "Something went wrong in the backend.", id, conn)
  end

  # --- Health -----------------------------------------------------------------------

  defp schedule_health(conn) do
    %{conn | health_timer: Process.send_after(self(), :health_tick, conn.opts.health_interval_ms)}
  end

  # If the health process is restarting, skip this push instead of crashing the
  # connection; the next tick will catch up.
  defp health_frame(conn) do
    {:text, Envelope.encode("health", nil, Health.payload(conn.opts.health))}
  catch
    :exit, reason ->
      Logger.warning("gateway: health unavailable, skipping push: #{inspect(reason)}")
      nil
  end

  # --- Replies ----------------------------------------------------------------------

  defp push_error(code, message, id, conn),
    do: {:push, [{:text, Envelope.error(code, message, id)}], conn}

  defp reject(code, message, id, conn, extra \\ %{}) do
    cancel_timer(conn.hello_timer)
    frame = {:text, Envelope.error(code, message, id, extra)}

    {:stop, :normal, {@policy_violation, Atom.to_string(code)}, [frame],
     %{conn | hello_timer: nil}}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)
end
