defmodule Quicksilver.Integrations.Supervisor do
  @moduledoc """
  The data-source subtree (started by `Quicksilver.Application` between
  `Health` and the gateway Endpoint).

      Quicksilver.Integrations.Supervisor        rest_for_one
      ├── Quicksilver.Integrations.PubSub         Registry (duplicate keys)
      ├── Quicksilver.Integrations.TaskSupervisor Task.Supervisor for fetches
      ├── Quicksilver.Integrations.RateLimiter    header-driven limiter
      ├── Quicksilver.Integrations.Leagues        league list + current league
      └── Quicksilver.Integrations.PoeNinja       poe.ninja cache + schedule

  **Why `rest_for_one`.** Each child depends on the ones above it: the servers
  subscribe through PubSub, fetch through tasks and the limiter, and PoeNinja
  follows Leagues. If one crashes, everything after it restarts with it, so no
  server keeps a stale subscription or a ticket from a dead limiter. A
  crash here never touches the gateway (the application uses `one_for_one`).
  Caches are in memory, so a restart refetches (rate-limited as usual).

  HTTP failures are not crashes: they are reported to `Quicksilver.Health` and
  retried on the documented back-off.
  """

  use Supervisor

  alias Quicksilver.Integrations.{Config, Leagues, PoeNinja, PubSub, RateLimiter}

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    config = Config.all()
    http = [adapter: config[:http_adapter], limiter: RateLimiter]

    children = [
      {PubSub, name: PubSub},
      {Task.Supervisor, name: Quicksilver.Integrations.TaskSupervisor},
      {RateLimiter,
       name: RateLimiter, health_sources: %{trade_leagues: :trade_leagues, poe_ninja: :poe_ninja}},
      {Leagues, name: Leagues, http: http, auto_refresh: config[:auto_refresh]},
      {PoeNinja,
       name: PoeNinja,
       http: http,
       auto_refresh: config[:auto_refresh],
       types: config[:poe_ninja_types]}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
