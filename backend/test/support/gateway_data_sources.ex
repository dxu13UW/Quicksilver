defmodule Quicksilver.Test.StackSource do
  @moduledoc """
  `Quicksilver.Gateway.DataSource` over an isolated integrations stack started
  with `Quicksilver.IntegrationsCase.start_base/2` (+ `start_leagues/2`,
  `start_ninja/2`). `arg` is the map `start_base/2` returns. Same code paths as
  `Quicksilver.Integrations`, but on the test's own processes and the fixture
  HTTP adapter, so nothing touches the app's processes or the network.
  """

  @behaviour Quicksilver.Gateway.DataSource

  alias Quicksilver.Integrations.{Leagues, PoeNinja, PubSub}

  @impl true
  def list_leagues(b, timeout), do: Leagues.list(b.leagues, timeout)

  @impl true
  def current_league(b), do: Leagues.current(b.leagues)

  @impl true
  def set_league(b, id), do: Leagues.set_current(b.leagues, id)

  @impl true
  def rates(b, opts), do: PoeNinja.rates(b.ninja, opts)

  @impl true
  def subscribe(b, topic), do: PubSub.subscribe(b.pubsub, topic)

  @impl true
  def unsubscribe(b, topic), do: PubSub.unsubscribe(b.pubsub, topic)
end

defmodule Quicksilver.Test.ScriptedSource do
  @moduledoc """
  `Quicksilver.Gateway.DataSource` whose answers are scripted per test, for
  outcomes a real stack can't easily produce (`:no_league`, a failed settings
  write, a crash, a job that blocks until the test releases it).

  `arg` is a map: `:pubsub` (a `Quicksilver.Integrations.PubSub` registry,
  required) plus optional funs `:list_leagues` (timeout), `:current_league` (),
  `:set_league` (id), `:rates` (opts). Funs run in the gateway's task, so they
  may block or raise. Missing funs answer with the defaults below.
  """

  @behaviour Quicksilver.Gateway.DataSource

  alias Quicksilver.Integrations.PubSub

  @leagues [%{id: "Covens", text: "Covens"}, %{id: "Standard", text: "Standard"}]

  @impl true
  def list_leagues(arg, timeout), do: call(arg, :list_leagues, [timeout], {:ok, @leagues})

  @impl true
  def current_league(arg), do: call(arg, :current_league, [], "Covens")

  @impl true
  def set_league(arg, id), do: call(arg, :set_league, [id], :ok)

  @impl true
  def rates(arg, opts), do: call(arg, :rates, [opts], {:ok, sample_rates()})

  @impl true
  def subscribe(arg, topic), do: PubSub.subscribe(arg.pubsub, topic)

  @impl true
  def unsubscribe(arg, topic), do: PubSub.unsubscribe(arg.pubsub, topic)

  @doc "A small rates map shaped like `Quicksilver.Integrations.rates/1` returns."
  def sample_rates(league \\ "Covens", divine_chaos \\ 216.2) do
    %{
      league: league,
      source: "poe_ninja",
      fetched_at: ~U[2026-11-19 21:00:00.123456Z],
      stale: false,
      divine_chaos: divine_chaos,
      rates: [
        %{
          id: "divine",
          name: "Divine Orb",
          chaos: divine_chaos,
          divine: 1.0,
          change_7d: -2.1,
          volume_chaos: 120_345.6
        },
        %{
          id: "exalted",
          name: "Exalted Orb",
          chaos: 15.0,
          divine: 15.0 / divine_chaos,
          change_7d: nil,
          volume_chaos: nil
        }
      ]
    }
  end

  defp call(arg, key, args, default) do
    case Map.fetch(arg, key) do
      {:ok, fun} -> apply(fun, args)
      :error -> default
    end
  end
end
