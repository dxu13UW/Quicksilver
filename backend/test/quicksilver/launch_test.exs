defmodule Quicksilver.LaunchTest do
  # PROTOCOL.md "Launch and lifetime"; CON-1.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  alias Quicksilver.Launch

  test "ready line is exactly the PROTOCOL format" do
    assert Launch.ready_line(53123) == ~s(QUICKSILVER_READY {"port":53123,"protocol_version":1})
  end

  test "announce prints one line to the device" do
    out = capture_io(fn -> Launch.announce(4242) end)
    assert out == ~s(QUICKSILVER_READY {"port":4242,"protocol_version":1}\n)
  end

  test "env: defaults to port 47474 and no token" do
    assert {:ok, %{port: 47474, token: nil, exit_on_stdin_eof: true}} = Launch.parse_env(%{})

    assert {:ok, %{port: 47474, token: nil}} =
             Launch.parse_env(%{"QUICKSILVER_PORT" => "", "QUICKSILVER_TOKEN" => " "})
  end

  test "env: port 0 and explicit values" do
    assert {:ok, %{port: 0, token: "abc"}} =
             Launch.parse_env(%{"QUICKSILVER_PORT" => "0", "QUICKSILVER_TOKEN" => "abc"})

    assert {:ok, %{port: 50000}} = Launch.parse_env(%{"QUICKSILVER_PORT" => " 50000 "})
  end

  test "env: invalid ports are errors" do
    for bad <- ["-1", "65536", "abc", "12x", "1.5"] do
      assert {:error, msg} = Launch.parse_env(%{"QUICKSILVER_PORT" => bad})
      assert msg =~ "QUICKSILVER_PORT"
    end
  end

  test "env: stdin watch can be turned off for development" do
    assert {:ok, %{exit_on_stdin_eof: false}} =
             Launch.parse_env(%{"QUICKSILVER_EXIT_ON_STDIN_EOF" => "0"})
  end
end
