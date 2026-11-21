defmodule Quicksilver.Gateway.DataSource do
  @moduledoc """
  The gateway's view of the data sources: the calls the Dashboard handler
  (`Quicksilver.Gateway.Handlers.Dashboard`) makes.

  The gateway option `:data_source` is `{module, arg}`; every callback gets
  `arg` first. Production uses `{Quicksilver.Gateway.DataSource.Integrations, nil}`,
  which forwards to the public `Quicksilver.Integrations` API. Tests plug in
  an isolated integrations stack or a scripted stub, so they never touch the
  application's own processes or the network.

  Return values are exactly those of `Quicksilver.Integrations`.

  Which process calls what matters:

    * `subscribe/2` and `unsubscribe/2` are called from the connection process
      itself, because the subscription belongs to the caller.
    * `list_leagues/2`, `current_league/1`, `set_league/2` and `rates/2` are
      called from a task (they may wait on the network), never from the
      connection process.
  """

  @type arg :: term()
  @type topic :: :rates | :league

  @callback list_leagues(arg(), timeout()) ::
              {:ok, [%{id: String.t(), text: String.t()}]} | {:error, :unavailable}
  @callback current_league(arg()) :: String.t() | nil
  @callback set_league(arg(), String.t()) ::
              :ok | {:error, :unknown_league | :unavailable | {:settings, term()}}
  @callback rates(arg(), keyword()) ::
              {:ok, map()} | {:error, :no_league | :league_not_covered | :unavailable}
  @callback subscribe(arg(), topic()) :: :ok
  @callback unsubscribe(arg(), topic()) :: :ok
end

defmodule Quicksilver.Gateway.DataSource.Integrations do
  @moduledoc "Production `Quicksilver.Gateway.DataSource`: the app's `Quicksilver.Integrations`."

  @behaviour Quicksilver.Gateway.DataSource

  alias Quicksilver.Integrations

  @impl true
  def list_leagues(_arg, timeout), do: Integrations.list_leagues(timeout)

  @impl true
  def current_league(_arg), do: Integrations.current_league()

  @impl true
  def set_league(_arg, id), do: Integrations.set_league(id)

  @impl true
  def rates(_arg, opts), do: Integrations.rates(opts)

  @impl true
  def subscribe(_arg, topic), do: Integrations.subscribe(topic)

  @impl true
  def unsubscribe(_arg, topic), do: Integrations.unsubscribe(topic)
end
