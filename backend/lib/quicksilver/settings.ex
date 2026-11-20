defmodule Quicksilver.Settings do
  @moduledoc """
  User settings persisted as `settings.json` (PROTOCOL.md "Settings file").

  Location: `:filename.basedir(:user_config, "Quicksilver")`, which is
  `%APPDATA%\\Quicksilver\\` on Windows and `~/.config/Quicksilver/` on Linux.
  Override with app env `config :quicksilver, settings_dir: "..."`, or per
  instance with the `:dir` start option (tests do this).

  Keys are strings, exactly as stored in the JSON object. Atom keys are accepted
  and converted. Known keys today:

    * `"league"`: the saved league id (DASH-2), or absent.
    * `"trade_api_enabled"`: the ADR-004 kill switch; absent means `true`.

  Keys this version doesn't know are kept when the file is rewritten, so a newer
  build's settings survive a downgrade.

  ## Why a process

  One GenServer owns the file so read-modify-write cycles are serialised (two
  quick `league.set` calls can't lose an update) and reads are served from memory.

  ## Durability

  `put/2` writes the whole object to a temp file in the same directory, fsyncs it,
  then renames it over `settings.json`. A crash mid-write leaves either the old
  file or the new one, never a truncated one. The in-memory copy only changes
  after the rename succeeds, so memory and disk agree.

  A file that isn't a JSON object is renamed to `settings.json.corrupt` and the
  backend starts with defaults instead of refusing to boot.
  """

  use GenServer
  require Logger

  @file_name "settings.json"

  # --- Public API -------------------------------------------------------------

  @doc """
  Starts the settings server.

  Options: `:name` (default `#{inspect(__MODULE__)}`), `:dir` (default from app
  env `:settings_dir`, else the OS user config directory).
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The default settings directory for this OS and app env."
  @spec default_dir() :: Path.t()
  def default_dir do
    Application.get_env(:quicksilver, :settings_dir) ||
      :filename.basedir(:user_config, "Quicksilver")
  end

  @doc "Reads `key` from the default server."
  @spec get(String.t() | atom(), term()) :: term()
  def get(key, default \\ nil), do: get(__MODULE__, key, default)

  @doc "Reads `key` from `server`."
  @spec get(GenServer.server(), String.t() | atom(), term()) :: term()
  def get(server, key, default), do: GenServer.call(server, {:get, to_key(key), default})

  @doc "Writes `key` on the default server. See `put/3`."
  @spec put(String.t() | atom(), term()) :: :ok | {:error, term()}
  def put(key, value), do: put(__MODULE__, key, value)

  @doc """
  Stores `value` under `key` and persists the file atomically.

  `value` must be JSON-encodable. Returns `{:error, reason}` (and leaves both
  memory and disk unchanged) if encoding or writing fails.
  """
  @spec put(GenServer.server(), String.t() | atom(), term()) :: :ok | {:error, term()}
  def put(server, key, value), do: GenServer.call(server, {:put, to_key(key), value})

  @doc "All settings as a map."
  @spec all(GenServer.server()) :: map()
  def all(server \\ __MODULE__), do: GenServer.call(server, :all)

  @doc "Full path of the settings file used by `server`."
  @spec path(GenServer.server()) :: Path.t()
  def path(server \\ __MODULE__), do: GenServer.call(server, :path)

  # --- GenServer --------------------------------------------------------------

  @impl true
  def init(opts) do
    dir = Keyword.get_lazy(opts, :dir, &default_dir/0)
    path = Path.join(dir, @file_name)
    remove_stale_temp_files(path)
    {:ok, %{path: path, data: load(path)}}
  end

  @impl true
  def handle_call({:get, key, default}, _from, state),
    do: {:reply, Map.get(state.data, key, default), state}

  def handle_call(:all, _from, state), do: {:reply, state.data, state}
  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  def handle_call({:put, key, value}, _from, state) do
    new_data = Map.put(state.data, key, value)

    case write_atomic(state.path, new_data) do
      :ok ->
        {:reply, :ok, %{state | data: new_data}}

      {:error, reason} = error ->
        Logger.error("settings: could not write #{state.path}: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  # --- File handling ----------------------------------------------------------

  defp load(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, %{} = data} <- Jason.decode(binary) do
      data
    else
      {:error, :enoent} ->
        %{}

      {:error, reason} when is_atom(reason) ->
        Logger.warning("settings: could not read #{path}: #{inspect(reason)}; using defaults")
        %{}

      _not_an_object_or_bad_json ->
        aside = path <> ".corrupt"

        Logger.warning(
          "settings: #{path} is not a JSON object; moved to #{aside}, using defaults"
        )

        _ = File.rename(path, aside)
        %{}
    end
  end

  defp write_atomic(path, data) do
    tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with {:ok, json} <- encode(data),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- write_and_sync(tmp, json),
         # Same directory, so this is a rename, not a copy. On Windows, OTP's
         # rename replaces an existing target file. Verify on the B6 build.
         :ok <- File.rename(tmp, path) do
      :ok
    else
      error ->
        _ = File.rm(tmp)
        error
    end
  end

  defp encode(data) do
    {:ok, Jason.encode_to_iodata!(data, pretty: true)}
  rescue
    e -> {:error, {:not_json_encodable, Exception.message(e)}}
  end

  defp write_and_sync(path, iodata) do
    with {:ok, fd} <- :file.open(path, [:write, :binary, :raw]) do
      try do
        with :ok <- :file.write(fd, iodata), do: :file.sync(fd)
      after
        :file.close(fd)
      end
    end
  end

  # Temp files are only left behind if the VM died between write and rename.
  defp remove_stale_temp_files(path) do
    dir = Path.dirname(path)
    prefix = Path.basename(path) <> ".tmp-"

    case File.ls(dir) do
      {:ok, names} ->
        for name <- names, String.starts_with?(name, prefix), do: File.rm(Path.join(dir, name))

      {:error, _} ->
        :ok
    end

    :ok
  end

  defp to_key(key) when is_binary(key), do: key
  defp to_key(key) when is_atom(key), do: Atom.to_string(key)
end
