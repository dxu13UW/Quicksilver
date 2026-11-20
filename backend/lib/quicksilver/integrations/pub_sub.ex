defmodule Quicksilver.Integrations.PubSub do
  @moduledoc """
  Minimal publish/subscribe on a `Registry` with duplicate keys.

  Topics and the messages a subscriber receives:

  | topic | message |
  |---|---|
  | `:league` | `{Quicksilver.Integrations, :league_changed, league_id}` |
  | `:rates` | `{Quicksilver.Integrations, :rates, rates}` (see `Quicksilver.Integrations.PoeNinja.rates/2`) |

  Subscriptions belong to the calling process and disappear when it exits.
  `subscribe/2` is idempotent: subscribing twice still delivers each message
  once. If the registry itself restarts (its supervisor uses `:rest_for_one`,
  so the integrations servers restart with it), subscriptions are lost and
  callers must subscribe again; that only happens after a crash.
  """

  @type topic :: :league | :rates

  @doc false
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Registry.child_spec(keys: :duplicate, name: name)
  end

  @doc "Subscribes the calling process to `topic`."
  @spec subscribe(atom(), topic()) :: :ok
  def subscribe(registry \\ __MODULE__, topic) do
    unless subscribed?(registry, topic) do
      {:ok, _} = Registry.register(registry, topic, nil)
    end

    :ok
  end

  @doc "Unsubscribes the calling process from `topic`."
  @spec unsubscribe(atom(), topic()) :: :ok
  def unsubscribe(registry \\ __MODULE__, topic), do: Registry.unregister(registry, topic)

  @doc "Sends `{Quicksilver.Integrations, event, payload}` to every subscriber of `topic`."
  @spec broadcast(atom(), topic(), atom(), term()) :: :ok
  def broadcast(registry \\ __MODULE__, topic, event, payload) do
    Registry.dispatch(registry, topic, fn entries ->
      for {pid, _} <- entries, do: send(pid, {Quicksilver.Integrations, event, payload})
    end)
  end

  defp subscribed?(registry, topic), do: topic in Registry.keys(registry, self())
end
