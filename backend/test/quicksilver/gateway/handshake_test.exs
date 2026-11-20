defmodule Quicksilver.Gateway.HandshakeTest do
  # CON-2, NFR-SEC-2.
  use ExUnit.Case, async: true

  alias Quicksilver.Gateway.Handshake

  @good %{"client_version" => "0.1.0", "protocol_version" => 1, "token" => "t0k"}

  test "accepts a correct hello" do
    assert {:ok, %{client_version: "0.1.0"}} = Handshake.check(@good, %{token: "t0k"})
  end

  test "token check is off when the backend has no token" do
    assert {:ok, _} = Handshake.check(Map.delete(@good, "token"), %{token: nil})
  end

  test "wrong, missing or non-string token is unauthorized" do
    for payload <- [
          %{@good | "token" => "nope"},
          Map.delete(@good, "token"),
          %{@good | "token" => 1}
        ] do
      assert {:error, :unauthorized, _, %{}} = Handshake.check(payload, %{token: "t0k"})
    end
  end

  test "different integer version is protocol_mismatch with expected" do
    assert {:error, :protocol_mismatch, _, %{expected: 1}} =
             Handshake.check(%{@good | "protocol_version" => 0}, %{token: "t0k"})
  end

  test "missing or non-integer fields are bad_request" do
    for payload <- [
          Map.delete(@good, "protocol_version"),
          %{@good | "protocol_version" => 1.0},
          Map.delete(@good, "client_version"),
          %{@good | "client_version" => 1}
        ] do
      assert {:error, :bad_request, _, %{}} = Handshake.check(payload, %{token: "t0k"})
    end
  end
end
