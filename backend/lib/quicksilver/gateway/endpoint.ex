defmodule Quicksilver.Gateway.Endpoint do
  @moduledoc """
  The WebSocket listener: Bandit bound to `127.0.0.1` only (NFR-SEC-1).

  Options (all optional; defaults from app env, then the values below):

    * `:name`: registered name of the listener (default `#{inspect(__MODULE__)}`).
    * `:port`: TCP port; `0` lets the OS choose (default `47474`).
    * `:token`: required `hello` token, or `nil` to turn the check off.
    * `:hello_timeout_ms` (5000), `:health_interval_ms` (5000).
    * `:max_frame_size` in bytes (1 MiB; item text is a few KB).
    * `:health` / `:settings`: the `Quicksilver.Health` / `Quicksilver.Settings`
      servers that connections use (default: the app's named instances).
    * `:data_source`: `{module, arg}` implementing `Quicksilver.Gateway.DataSource`
      (default: the app's `Quicksilver.Integrations`).
    * `:task_sup`: the `Task.Supervisor` that runs slow handler work
      (default `Quicksilver.Gateway.TaskSupervisor`).
    * `:upstream_timeout_ms` (15000): how long a request waits for a data
      source with nothing cached before answering `upstream_unavailable`.

  ## Port across restarts

  The first successful bind remembers the actual port. If the listener crashes
  and its supervisor restarts it, it binds that same port again, so a client
  started with `QUICKSILVER_PORT=0` can still reconnect (CON-4) and the single
  `QUICKSILVER_READY` line stays true. If the port has been taken meanwhile, the
  bind fails, the supervisor gives up after its restart budget, and the backend
  exits; the client then reports the backend as gone.
  """

  @loopback {127, 0, 0, 1}

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      # permanent: the listener is the whole point of the service; always restart it.
      restart: :permanent
    }
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    port = remembered_port(name) || Keyword.get(opts, :port, Quicksilver.Launch.default_port())

    bandit_opts = [
      plug: {Quicksilver.Gateway.HTTP, gateway_opts(opts)},
      scheme: :http,
      ip: @loopback,
      port: port,
      # Logs go to stderr anyway, but the client-facing signal is the READY line.
      startup_log: false,
      thousand_island_options: [supervisor_options: [name: name]]
    ]

    with {:ok, pid} <- Bandit.start_link(bandit_opts) do
      :persistent_term.put({__MODULE__, name, :port}, port(pid))
      {:ok, pid}
    end
  end

  @doc "The port the listener is actually bound to."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server \\ __MODULE__) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  @doc "Builds the options map every connection receives."
  @spec gateway_opts(keyword()) :: map()
  def gateway_opts(opts) do
    app = Application.get_all_env(:quicksilver)

    %{
      token: Keyword.get(opts, :token),
      hello_timeout_ms:
        Keyword.get(opts, :hello_timeout_ms, Keyword.get(app, :hello_timeout_ms, 5_000)),
      health_interval_ms:
        Keyword.get(opts, :health_interval_ms, Keyword.get(app, :health_interval_ms, 5_000)),
      max_frame_size: Keyword.get(opts, :max_frame_size, 1_048_576),
      health: Keyword.get(opts, :health, Quicksilver.Health),
      settings: Keyword.get(opts, :settings, Quicksilver.Settings),
      data_source:
        Keyword.get(opts, :data_source, {Quicksilver.Gateway.DataSource.Integrations, nil}),
      task_sup: Keyword.get(opts, :task_sup, Quicksilver.Gateway.TaskSupervisor),
      upstream_timeout_ms:
        Keyword.get(opts, :upstream_timeout_ms, Keyword.get(app, :upstream_timeout_ms, 15_000))
    }
  end

  defp remembered_port(name), do: :persistent_term.get({__MODULE__, name, :port}, nil)
end
