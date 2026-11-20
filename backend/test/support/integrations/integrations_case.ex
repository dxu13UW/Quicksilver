defmodule Quicksilver.IntegrationsCase do
  @moduledoc """
  Helpers for integrations tests: an isolated stack (own Health, Settings,
  PubSub, task supervisor, limiter) with uniquely named processes, so tests can
  run async and never touch the application's processes or the network.
  """

  use ExUnit.CaseTemplate

  alias Quicksilver.Integrations.{FixtureHTTP, Leagues, PoeNinja, RateLimiter}

  using do
    quote do
      import Quicksilver.IntegrationsCase
      alias Quicksilver.Integrations.{FixtureHTTP, Urls}
    end
  end

  @doc """
  Starts Health, Settings (in `dir`), PubSub, a task supervisor and a limiter.
  Returns a map of their names plus `:http` (adapter + limiter) for servers.
  """
  def start_base(routes, dir) do
    n = System.unique_integer([:positive])

    names = %{
      health: :"health_#{n}",
      settings: :"settings_#{n}",
      pubsub: :"pubsub_#{n}",
      task_sup: :"tasks_#{n}",
      limiter: :"limiter_#{n}",
      leagues: :"leagues_#{n}",
      ninja: :"ninja_#{n}"
    }

    start_supervised!({Quicksilver.Health, name: names.health}, id: :health)
    start_supervised!({Quicksilver.Settings, name: names.settings, dir: dir}, id: :settings)
    start_supervised!({Quicksilver.Integrations.PubSub, name: names.pubsub}, id: :pubsub)
    start_supervised!({Task.Supervisor, name: names.task_sup}, id: :task_sup)

    start_supervised!(
      {RateLimiter,
       name: names.limiter,
       health: names.health,
       health_sources: %{trade_leagues: :trade_leagues, poe_ninja: :poe_ninja}},
      id: :limiter
    )

    adapter = FixtureHTTP.start(routes)
    Map.merge(names, %{adapter: adapter, http: [adapter: adapter, limiter: names.limiter]})
  end

  @doc "Starts a Leagues server on the base stack."
  def start_leagues(base, opts \\ []) do
    opts =
      Keyword.merge(
        [
          name: base.leagues,
          pubsub: base.pubsub,
          health: base.health,
          settings: base.settings,
          task_sup: base.task_sup,
          http: base.http,
          auto_refresh: false
        ],
        opts
      )

    start_supervised!({Leagues, opts}, id: :leagues)
  end

  @doc "Starts a PoeNinja server on the base stack (needs Leagues)."
  def start_ninja(base, opts \\ []) do
    opts =
      Keyword.merge(
        [
          name: base.ninja,
          pubsub: base.pubsub,
          health: base.health,
          leagues: base.leagues,
          task_sup: base.task_sup,
          http: base.http,
          auto_refresh: false,
          types: [{:exchange, "Currency"}, {:stash, "UniqueAccessory"}]
        ],
        opts
      )

    start_supervised!({PoeNinja, opts}, id: :ninja)
  end

  @doc "Health entry for `name` (string) from `server`."
  def health_entry(server, name),
    do: Enum.find(Quicksilver.Health.snapshot(server), &(&1.name == name))

  @doc "Retries `fun` until it returns a truthy value (Health reports are casts)."
  def eventually(fun, tries \\ 100) do
    case fun.() do
      v when v in [nil, false] ->
        if tries == 0, do: raise("condition not met in time")
        Process.sleep(10)
        eventually(fun, tries - 1)

      v ->
        v
    end
  end

  @doc "URLs requested so far."
  def requested_urls(base), do: base.adapter |> FixtureHTTP.requests() |> Enum.map(&elem(&1, 1))
end
