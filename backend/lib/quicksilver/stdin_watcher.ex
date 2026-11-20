defmodule Quicksilver.StdinWatcher do
  @moduledoc """
  Stops the backend when stdin closes (PROTOCOL.md "Cleanup", best effort).

  The production client's Windows Job Object is the real guarantee that the
  backend dies with the client (CON-1). This is the second guard: the client
  holds the write end of our stdin pipe, so when the client exits, crashes, or
  closes the pipe on purpose, the read here returns `:eof` and we shut down
  cleanly with `System.stop(0)`.

  Disabled when:
    * app env `exit_on_stdin_eof: false` (set in `config/test.exs`),
    * `QUICKSILVER_EXIT_ON_STDIN_EOF=0` in the environment (development, e.g.
      running in the background with stdin at `/dev/null`),
    * running under IEx, because the shell owns stdin.

  Any line written to stdin is read and ignored.
  """

  # transient: a normal return (stdin unreadable, watcher gives up) must not be
  # restarted into a tight loop; an unexpected crash is restarted.
  use Task, restart: :transient

  require Logger

  @doc """
  Options: `:device` (default `:stdio`), `:on_eof` (zero-arity fun, default
  `fn -> System.stop(0) end`).
  """
  def start_link(opts \\ []), do: Task.start_link(__MODULE__, :run, [opts])

  @doc "Whether the watcher should run, given the launch config."
  @spec enabled?(map()) :: boolean()
  def enabled?(launch) do
    Map.get(launch, :exit_on_stdin_eof, true) and not iex_running?()
  end

  defp iex_running?, do: Code.ensure_loaded?(IEx) and IEx.started?()

  @doc false
  def run(opts) do
    device = Keyword.get(opts, :device, :stdio)
    on_eof = Keyword.get(opts, :on_eof, fn -> System.stop(0) end)
    loop(device, on_eof)
  end

  defp loop(device, on_eof) do
    case IO.binread(device, :line) do
      :eof ->
        Logger.info("stdin closed; shutting down")
        on_eof.()

      {:error, reason} ->
        Logger.warning("stdin is not readable (#{inspect(reason)}); exit-on-stdin-close is off")

      _line ->
        loop(device, on_eof)
    end
  end
end
