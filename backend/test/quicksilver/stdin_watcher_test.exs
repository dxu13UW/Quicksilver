defmodule Quicksilver.StdinWatcherTest do
  # CON-1 second guard: exit when stdin closes.
  use ExUnit.Case, async: true

  alias Quicksilver.StdinWatcher

  test "calls on_eof once input ends, after consuming any lines" do
    {:ok, device} = StringIO.open("ignored line\nanother\n")
    test = self()

    ExUnit.CaptureLog.capture_log(fn ->
      {:ok, pid} = StdinWatcher.start_link(device: device, on_eof: fn -> send(test, :eof) end)
      assert_receive :eof, 1_000
      ref = Process.monitor(pid)
      # :noproc if it already finished before the monitor was set up.
      assert_receive {:DOWN, ^ref, :process, ^pid, reason} when reason in [:normal, :noproc],
                     1_000
    end)
  end

  test "is disabled by the launch flag" do
    refute StdinWatcher.enabled?(%{exit_on_stdin_eof: false})
  end
end
