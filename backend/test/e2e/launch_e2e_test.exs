defmodule Quicksilver.LaunchE2ETest do
  # CON-1, CON-2 end to end: boots the backend the way the client does
  # (QUICKSILVER_PORT=0, a token), reads the READY line from stdout, completes a
  # handshake, then closes stdin and checks the backend exits.
  #
  # Excluded by default (slow; compiles and runs the dev build). Run with:
  #   mix test --include e2e
  use ExUnit.Case, async: false

  @moduletag :e2e
  @moduletag timeout: 120_000

  import Quicksilver.GatewayCase, only: [hello: 1, recv_json!: 1]
  alias Quicksilver.Test.WSClient

  test "READY line, handshake, and exit on stdin close" do
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    {exe, args} = mix_command(["run", "--no-halt"])

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        {:line, 4096},
        args: args,
        cd: File.cwd!(),
        env: [
          {~c"MIX_ENV", ~c"dev"},
          {~c"QUICKSILVER_PORT", ~c"0"},
          {~c"QUICKSILVER_TOKEN", String.to_charlist(token)},
          {~c"QUICKSILVER_EXIT_ON_STDIN_EOF", ~c"1"},
          # No live requests from the dev boot (integrations use HTTP.Disabled).
          {~c"QUICKSILVER_OFFLINE", ~c"1"}
        ]
      ])

    {tcp_port, stdout_lines} = await_ready(port, [])
    assert Enum.count(stdout_lines, &String.starts_with?(&1, "QUICKSILVER_READY")) == 1

    {:ok, client} = WSClient.connect(tcp_port)
    WSClient.send_json(client, hello(token))
    assert recv_json!(client)["type"] == "welcome"
    assert recv_json!(client)["type"] == "health"

    # Closing the port closes the child's stdin.
    Port.close(port)
    assert_receive {:ws, ^client, _closed}, 10_000
    wait_until_refused(tcp_port)
  end

  # On Windows `mix` is mix.bat -> elixir.bat -> erl.exe under cmd.exe. Two
  # problems with that inside an Erlang port: cmd runs the registry AutoRun hook
  # (on some machines it prints a banner and changes directory), and output of
  # programs cmd starts never reaches the port's pipe. So start erl.exe directly
  # with the arguments elixir.bat would build.
  defp mix_command(args) do
    case :os.type() do
      {:win32, _} ->
        elixir_root = Path.dirname(to_string(:code.lib_dir(:elixir)))
        mix_script = Path.join([elixir_root, "..", "bin", "mix"]) |> Path.expand()

        {System.find_executable("erl"),
         [
           "-noshell",
           "-elixir_root",
           elixir_root,
           "-pa",
           Path.join([elixir_root, "elixir", "ebin"]),
           "-s",
           "elixir",
           "start_cli",
           "-extra",
           mix_script | args
         ]}

      _ ->
        {System.find_executable("mix"), args}
    end
  end

  defp await_ready(port, lines) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        lines = [line | lines]

        case Regex.run(~r/^QUICKSILVER_READY \{"port":(\d+),"protocol_version":1\}$/, line) do
          [_, n] -> {String.to_integer(n), lines}
          nil -> await_ready(port, lines)
        end

      {^port, {:exit_status, status}} ->
        flunk(
          "backend exited with #{status} before READY; stdout: #{inspect(Enum.reverse(lines))}"
        )
    after
      90_000 -> flunk("no READY line within 90 s")
    end
  end

  defp wait_until_refused(tcp_port, tries \\ 100) do
    case :gen_tcp.connect(~c"127.0.0.1", tcp_port, [], 200) do
      {:error, _} ->
        :ok

      {:ok, socket} ->
        :gen_tcp.close(socket)
        if tries == 0, do: flunk("backend still listening after stdin closed")
        Process.sleep(100)
        wait_until_refused(tcp_port, tries - 1)
    end
  end
end
