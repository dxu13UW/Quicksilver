defmodule Quicksilver.Application do
  @moduledoc """
  Boots the backend.

  ## Supervision tree

      Quicksilver.Supervisor                 one_for_one
      ├── Quicksilver.Settings               GenServer, permanent
      ├── Quicksilver.Health                 GenServer, permanent
      │   (integrations: data-source subtree goes here, see below)
      ├── Quicksilver.Gateway.Endpoint       Bandit listener on 127.0.0.1, permanent
      │   └── one process per WebSocket connection (Bandit/ThousandIsland, temporary)
      └── Quicksilver.StdinWatcher           Task, transient (omitted in tests and IEx)

  **Why `one_for_one`.** The children don't share state that a restart would
  invalidate: connections ask Settings and Health by name on each use, and
  tolerate either being briefly unavailable (they fall back to defaults or skip
  one health push). Restarting siblings would only drop healthy client
  connections for nothing (NFR-REL-1).

  **Order matters at startup.** Settings and Health start first so the first
  connection can use them; the listener starts last so nothing is accepted
  before the backend can answer. The data-source subtree that integrations adds
  for I1/I2 belongs between Health and the Endpoint, as its own supervisor, so
  a crashing fetcher is restarted inside that subtree and never touches the
  gateway.

  **Connections.** Each WebSocket connection runs in its own process under
  Bandit's connection supervisor, with restart `:temporary`: a crashed
  connection is not restarted by the server (the client reconnects, CON-4) and
  never affects other connections or the children above.

  **Restart budget.** The default (3 restarts in 5 s) is kept. If a child keeps
  crashing, the whole application stops and the process exits; the client then
  sees the backend as gone, which is better than a half-working backend.
  """

  use Application
  require Logger

  alias Quicksilver.{Launch, StdinWatcher}
  alias Quicksilver.Gateway.Endpoint

  @impl true
  def start(_type, _args) do
    launch = Launch.config!()

    if launch.token == nil do
      Logger.warning(
        "QUICKSILVER_TOKEN is not set: the hello token check is OFF. " <>
          "This is only acceptable in development; the client always sets it."
      )
    end

    children =
      [
        Quicksilver.Settings,
        Quicksilver.Health,
        Quicksilver.Integrations.Supervisor,
        {Endpoint, port: launch.port, token: launch.token}
      ] ++ stdin_watcher(launch)

    with {:ok, sup} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: Quicksilver.Supervisor) do
      port = Endpoint.port()
      Logger.info("Quicksilver #{Quicksilver.version()} listening on ws://127.0.0.1:#{port}/ws")

      if Application.get_env(:quicksilver, :announce_ready, true) do
        Launch.announce(port)
      end

      {:ok, sup}
    end
  end

  defp stdin_watcher(launch) do
    if StdinWatcher.enabled?(launch), do: [StdinWatcher], else: []
  end
end
