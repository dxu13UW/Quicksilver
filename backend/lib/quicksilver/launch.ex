defmodule Quicksilver.Launch do
  @moduledoc """
  Launch-time configuration and the readiness line (PROTOCOL.md "Launch and lifetime").

  Environment variables, read once at boot:

    * `QUICKSILVER_PORT`: TCP port to bind on `127.0.0.1`. Unset or empty means
      47474. `0` means the OS picks a free port (what the production client uses).
    * `QUICKSILVER_TOKEN`: the per-launch token the client must present in `hello`.
      Unset or empty turns the token check off (development only); a warning is logged.
    * `QUICKSILVER_EXIT_ON_STDIN_EOF`: development convenience, not part of the
      protocol. Set to `0` to keep running when stdin closes, e.g. when started in
      the background with stdin at `/dev/null`. The client never sets it.

  When the listener is up, `announce/2` writes exactly one line to stdout:

      QUICKSILVER_READY {"port":53123,"protocol_version":1}
  """

  @default_port 47474

  @type t :: %{port: :inet.port_number(), token: String.t() | nil, exit_on_stdin_eof: boolean()}

  @doc "The development default port."
  @spec default_port() :: :inet.port_number()
  def default_port, do: @default_port

  @doc """
  Resolves launch configuration.

  With app env `read_launch_env: true` (the default) the values come from the OS
  environment. Tests set it to `false` and use the app env keys `:port`, `:token`
  and `:exit_on_stdin_eof` instead, so a stray exported variable can't break them.

  Raises `ArgumentError` with a readable message on an invalid `QUICKSILVER_PORT`:
  failing to boot is better than silently binding a different port than asked.
  """
  @spec config!() :: t()
  def config! do
    app = Application.get_all_env(:quicksilver)

    if Keyword.get(app, :read_launch_env, true) do
      case parse_env(System.get_env()) do
        {:ok, config} -> config
        {:error, message} -> raise ArgumentError, message
      end
    else
      %{
        port: Keyword.get(app, :port, @default_port),
        token: Keyword.get(app, :token),
        exit_on_stdin_eof: Keyword.get(app, :exit_on_stdin_eof, true)
      }
    end
  end

  @doc "Pure parser for the launch environment variables. See the module doc."
  @spec parse_env(%{optional(String.t()) => String.t()}) :: {:ok, t()} | {:error, String.t()}
  def parse_env(env) when is_map(env) do
    with {:ok, port} <- parse_port(Map.get(env, "QUICKSILVER_PORT")) do
      {:ok,
       %{
         port: port,
         token: parse_token(Map.get(env, "QUICKSILVER_TOKEN")),
         exit_on_stdin_eof: Map.get(env, "QUICKSILVER_EXIT_ON_STDIN_EOF") not in ["0", "false"]
       }}
    end
  end

  defp parse_port(nil), do: {:ok, @default_port}

  defp parse_port(value) do
    case String.trim(value) do
      "" ->
        {:ok, @default_port}

      trimmed ->
        case Integer.parse(trimmed) do
          {port, ""} when port in 0..65_535 ->
            {:ok, port}

          _ ->
            {:error,
             "QUICKSILVER_PORT must be an integer from 0 to 65535, got: #{inspect(value)}"}
        end
    end
  end

  defp parse_token(nil), do: nil

  defp parse_token(value) do
    case String.trim(value) do
      "" -> nil
      token -> token
    end
  end

  @doc "The readiness line for `port`, without a trailing newline."
  @spec ready_line(:inet.port_number()) :: String.t()
  def ready_line(port) when is_integer(port) do
    # Built by hand rather than with Jason so the key order is exactly the one in
    # PROTOCOL.md; the client may match on the literal prefix.
    ~s(QUICKSILVER_READY {"port":#{port},"protocol_version":#{Quicksilver.protocol_version()}})
  end

  @doc """
  Writes the readiness line to `device` (stdout by default). Called exactly once,
  by `Quicksilver.Application.start/2`, after the listener is bound.
  """
  @spec announce(:inet.port_number(), IO.device()) :: :ok
  def announce(port, device \\ :stdio) do
    IO.puts(device, ready_line(port))
  end
end
