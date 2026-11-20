defmodule Quicksilver.Health do
  @moduledoc """
  Per-source status for the `health` push (PROTOCOL.md "Connection / health").

  One process holds the latest status of every external data source. Each client
  connection asks it for `payload/1` right after `welcome` and then every
  `health_interval_s`, and sends the result as a `health` push.

  ## API for data-source owners (integrations lane)

      Quicksilver.Health.report(:poe_ninja, status: :ok, cached_at: fetched_at)
      Quicksilver.Health.report(:poe_ninja, status: :degraded, detail: "HTTP 503")
      Quicksilver.Health.report(:trade_api,
        rate_limit: %{policy: "trade-search-request-limit", queued: 2, restricted_until: nil})

  `report(source, attrs)` merges `attrs` into the source's current entry.
  Fields you leave out keep their previous value. It returns `:ok` at once
  (an asynchronous cast) and never blocks or crashes the caller because of the
  health process; but invalid arguments raise `ArgumentError` **in the caller**,
  so a bug shows up in your own tests.

  `source` is an atom or string matching `~r/^[a-z0-9_]+$/`. It is the wire
  `name`. Names in PROTOCOL.md: `poe_ninja`, `trade_leagues` (both registered as
  `idle` at startup), `trade_api` (Week 3), `client_log` (Week 4). Reporting an
  unregistered source registers it.

  `attrs` (keyword list or map, atom keys; all optional):

  | key | type | meaning |
  |---|---|---|
  | `:status` | `:idle \\| :ok \\| :degraded \\| :down` | see the PROTOCOL table |
  | `:last_success` | `DateTime.t() \\| nil` | when the last request succeeded. If you report `status: :ok` without it, it is set to now. |
  | `:cached_at` | `DateTime.t() \\| nil` | when the data currently served was fetched. The wire field `cache_age_s` is computed from it at push time, so you don't need to re-report just to age it. |
  | `:detail` | `String.t() \\| nil` | short plain-language note for the UI, e.g. `"HTTP 503"`. Not a stack trace. |
  | `:rate_limit` | `nil \\| %{policy: String.t(), queued: non_neg_integer(), restricted_until: DateTime.t() \\| nil}` | rate-limit state for sources that have one |

  Other functions: `register/1` (add a source as `idle` without changing an
  existing entry), `snapshot/0` (internal representation), `payload/0`
  (the exact wire payload of `health`).

  ## Ordering

  Sources are listed in PROTOCOL order (`poe_ninja`, `trade_leagues`,
  `trade_api`, `client_log`), then any other source in registration order. The
  client shows them in the order given.

  ## Restart behaviour

  If this process crashes, its supervisor restarts it with every default source
  back at `idle`; the next `report/2` from each owner restores the real state.
  Callers are unaffected because `report/2` is a cast.
  """

  use GenServer

  @statuses [:idle, :ok, :degraded, :down]
  @protocol_order ~w(poe_ninja trade_leagues trade_api client_log)
  @attr_keys [:status, :last_success, :cached_at, :detail, :rate_limit]
  @default_sources ~w(poe_ninja trade_leagues)

  @type source :: atom() | String.t()
  @type status :: :idle | :ok | :degraded | :down
  @type rate_limit :: %{
          policy: String.t(),
          queued: non_neg_integer(),
          restricted_until: DateTime.t() | nil
        }
  @type entry :: %{
          name: String.t(),
          status: status(),
          last_success: DateTime.t() | nil,
          cached_at: DateTime.t() | nil,
          detail: String.t() | nil,
          rate_limit: rate_limit() | nil
        }

  # --- Public API -------------------------------------------------------------

  @doc """
  Starts the health server.

  Options: `:name` (default `#{inspect(__MODULE__)}`), `:sources` (names
  registered as `idle` at start; default from app env `:health_sources`, else
  `#{inspect(@default_sources)}`).
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Reports the status of `source` to the default server. See the module doc."
  @spec report(source(), keyword() | map()) :: :ok
  def report(source, attrs), do: report(__MODULE__, source, attrs)

  @doc "Same as `report/2`, against a specific server (used by tests)."
  @spec report(GenServer.server(), source(), keyword() | map()) :: :ok
  def report(server, source, attrs) do
    name = validate_source!(source)
    attrs = validate_attrs!(attrs)
    GenServer.cast(server, {:report, name, attrs})
  end

  @doc "Registers `source` as `idle` if it isn't known yet. Never changes an existing entry."
  @spec register(GenServer.server(), source()) :: :ok
  def register(server \\ __MODULE__, source) do
    GenServer.cast(server, {:register, validate_source!(source)})
  end

  @doc "All sources in display order, internal representation."
  @spec snapshot(GenServer.server()) :: [entry()]
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @doc """
  The exact `health` payload from PROTOCOL.md, with timestamps formatted and
  `cache_age_s` computed against the current time. Ready for `Jason.encode!/1`.
  """
  @spec payload(GenServer.server()) :: map()
  def payload(server \\ __MODULE__) do
    now = DateTime.utc_now()

    %{
      uptime_s: uptime_s(),
      sources: Enum.map(snapshot(server), &wire_source(&1, now))
    }
  end

  @doc "Seconds since the VM started. Unaffected by restarts of this process."
  @spec uptime_s() :: non_neg_integer()
  def uptime_s do
    {wall_ms, _since_last} = :erlang.statistics(:wall_clock)
    div(wall_ms, 1000)
  end

  # --- GenServer --------------------------------------------------------------

  @impl true
  def init(opts) do
    defaults =
      Keyword.get_lazy(opts, :sources, fn ->
        Application.get_env(:quicksilver, :health_sources, @default_sources)
      end)

    state =
      Enum.reduce(defaults, %{entries: %{}, order: []}, &put_new_source(&2, validate_source!(&1)))

    {:ok, state}
  end

  @impl true
  def handle_cast({:register, name}, state), do: {:noreply, put_new_source(state, name)}

  def handle_cast({:report, name, attrs}, state) do
    state = put_new_source(state, name)
    entry = Map.merge(state.entries[name], attrs)

    entry =
      if attrs[:status] == :ok and not Map.has_key?(attrs, :last_success),
        do: %{entry | last_success: DateTime.utc_now()},
        else: entry

    {:noreply, put_in(state.entries[name], entry)}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    entries =
      state.order
      |> Enum.with_index()
      |> Enum.sort_by(fn {name, i} -> {protocol_rank(name), i} end)
      |> Enum.map(fn {name, _} -> state.entries[name] end)

    {:reply, entries, state}
  end

  # --- Helpers ----------------------------------------------------------------

  defp put_new_source(%{entries: entries} = state, name) when is_map_key(entries, name), do: state

  defp put_new_source(state, name) do
    entry = %{
      name: name,
      status: :idle,
      last_success: nil,
      cached_at: nil,
      detail: nil,
      rate_limit: nil
    }

    %{state | entries: Map.put(state.entries, name, entry), order: state.order ++ [name]}
  end

  defp protocol_rank(name) do
    Enum.find_index(@protocol_order, &(&1 == name)) || length(@protocol_order)
  end

  defp wire_source(entry, now) do
    %{
      name: entry.name,
      status: Atom.to_string(entry.status),
      last_success: Quicksilver.Time.iso8601_ms(entry.last_success),
      cache_age_s: cache_age_s(entry.cached_at, now),
      detail: entry.detail,
      rate_limit: wire_rate_limit(entry.rate_limit)
    }
  end

  defp cache_age_s(nil, _now), do: nil
  defp cache_age_s(cached_at, now), do: max(0, DateTime.diff(now, cached_at, :second))

  defp wire_rate_limit(nil), do: nil

  defp wire_rate_limit(rl) do
    %{
      policy: rl.policy,
      queued: rl.queued,
      restricted_until: Quicksilver.Time.iso8601_ms(rl.restricted_until)
    }
  end

  # --- Validation (runs in the caller) ---------------------------------------

  defp validate_source!(source)
       when is_atom(source) and not is_nil(source) and not is_boolean(source),
       do: validate_source!(Atom.to_string(source))

  defp validate_source!(source) when is_binary(source) do
    if source =~ ~r/^[a-z0-9_]+$/,
      do: source,
      else:
        raise(ArgumentError, "health source must match ~r/^[a-z0-9_]+$/, got: #{inspect(source)}")
  end

  defp validate_source!(other),
    do: raise(ArgumentError, "health source must be an atom or string, got: #{inspect(other)}")

  defp validate_attrs!(attrs) when is_list(attrs) or is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when key in @attr_keys ->
        {key, validate_attr!(key, value)}

      {key, _} ->
        raise ArgumentError,
              "unknown health attribute #{inspect(key)}; allowed: #{inspect(@attr_keys)}"
    end)
  end

  defp validate_attrs!(other),
    do: raise(ArgumentError, "health attrs must be a keyword list or map, got: #{inspect(other)}")

  defp validate_attr!(:status, s) when s in @statuses, do: s
  defp validate_attr!(:status, s), do: bad_attr!(:status, s, "one of #{inspect(@statuses)}")

  defp validate_attr!(key, v) when key in [:last_success, :cached_at] do
    case v do
      nil -> nil
      %DateTime{} -> v
      _ -> bad_attr!(key, v, "a DateTime or nil")
    end
  end

  defp validate_attr!(:detail, v) when is_nil(v) or is_binary(v), do: v
  defp validate_attr!(:detail, v), do: bad_attr!(:detail, v, "a string or nil")

  defp validate_attr!(:rate_limit, nil), do: nil

  defp validate_attr!(:rate_limit, rl) when is_list(rl) or is_map(rl) do
    rl = Map.new(rl)

    case rl do
      %{policy: p, queued: q} when is_binary(p) and is_integer(q) and q >= 0 ->
        until = Map.get(rl, :restricted_until)

        unless is_nil(until) or is_struct(until, DateTime),
          do: bad_attr!(:rate_limit, rl, "restricted_until to be a DateTime or nil")

        %{policy: p, queued: q, restricted_until: until}

      _ ->
        bad_attr!(
          :rate_limit,
          rl,
          "%{policy: String.t(), queued: non_neg_integer(), restricted_until: DateTime.t() | nil}"
        )
    end
  end

  defp validate_attr!(:rate_limit, v), do: bad_attr!(:rate_limit, v, "a map or nil")

  defp bad_attr!(key, value, expected),
    do:
      raise(
        ArgumentError,
        "health attribute #{inspect(key)} must be #{expected}, got: #{inspect(value)}"
      )
end
