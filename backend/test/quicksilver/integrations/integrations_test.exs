defmodule Quicksilver.IntegrationsTest do
  # NFR-MNT-1 (the app's integrations never reach the network in tests),
  # NFR-API-2 (single client path), DASH-1/DASH-2 (API the Dashboard routes use).
  # The application's own integrations subtree in the test env: up, offline,
  # idle, and its public API usable by the gateway (Phase C).
  # Uses the application's named processes, so not async.
  use ExUnit.Case, async: false

  alias Quicksilver.Integrations

  test "the subtree runs under the application, in order, and never fetches in tests" do
    ids =
      Integrations.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))
      |> Enum.reverse()

    assert ids == [
             Integrations.PubSub,
             Integrations.TaskSupervisor,
             Integrations.RateLimiter,
             Integrations.Leagues,
             Integrations.PoeNinja
           ]

    refute Integrations.Config.get(:auto_refresh)
    assert Integrations.Config.http_adapter() == Integrations.HTTP.Disabled
  end

  test "subscribe is idempotent and messages arrive once" do
    :ok = Integrations.subscribe(:league)
    :ok = Integrations.subscribe(:league)
    Integrations.PubSub.broadcast(Integrations.PubSub, :league, :league_changed, "X")
    assert_receive {Integrations, :league_changed, "X"}
    refute_receive {Integrations, :league_changed, "X"}, 50

    :ok = Integrations.unsubscribe(:league)
    Integrations.PubSub.broadcast(Integrations.PubSub, :league, :league_changed, "Y")
    refute_receive {Integrations, :league_changed, "Y"}, 50
  end

  test "item_prices for an untracked type" do
    assert {:error, :not_tracked} = Integrations.item_prices("SkillGem")
  end
end
