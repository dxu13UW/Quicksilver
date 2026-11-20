defmodule Quicksilver.Gateway.EnvelopeTest do
  # NFR-MNT-2: envelope shape from PROTOCOL.md.
  use ExUnit.Case, async: true

  alias Quicksilver.Gateway.Envelope

  describe "decode/1" do
    test "accepts a full envelope and ignores unknown fields" do
      frame = ~s({"type":"a.b","id":"c-1","ts":"x","payload":{"k":1},"future":true})
      assert {:ok, %{type: "a.b", id: "c-1", payload: %{"k" => 1}}} = Envelope.decode(frame)
    end

    test "id may be null or absent" do
      assert {:ok, %{id: nil}} = Envelope.decode(~s({"type":"a","id":null,"payload":{}}))
      assert {:ok, %{id: nil}} = Envelope.decode(~s({"type":"a","payload":{}}))
    end

    test "rejects non-JSON, non-objects and missing or mistyped type/payload" do
      for frame <- [
            "",
            "nope",
            "[]",
            "1",
            ~s("s"),
            ~s({}),
            ~s({"type":"a"}),
            ~s({"payload":{}}),
            ~s({"type":"","payload":{}}),
            ~s({"type":1,"payload":{}}),
            ~s({"type":"a","payload":null}),
            ~s({"type":"a","id":5,"payload":{}})
          ] do
        assert {:error, message, _id} = Envelope.decode(frame), frame
        assert is_binary(message)
      end
    end

    test "errors keep a readable string id so the reply can echo it" do
      assert {:error, _, "c-4"} = Envelope.decode(~s({"type":"a","id":"c-4"}))
      assert {:error, _, nil} = Envelope.decode(~s({"type":"a","id":4}))
    end
  end

  describe "encode/3 and error/4" do
    test "produce type, id, ts (UTC ms, Z) and payload" do
      msg = Envelope.encode("welcome", "c-1", %{a: 1}) |> Jason.decode!()
      assert Map.keys(msg) |> Enum.sort() == ~w(id payload ts type)
      assert msg["ts"] =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/
      assert msg["payload"] == %{"a" => 1}
    end

    test "error payload has code and message, plus extras" do
      msg = Envelope.error(:protocol_mismatch, "m", nil, %{expected: 1}) |> Jason.decode!()
      assert msg["type"] == "error"
      assert msg["id"] == nil
      assert msg["payload"] == %{"code" => "protocol_mismatch", "message" => "m", "expected" => 1}
    end

    test "every PROTOCOL error code is accepted" do
      assert Envelope.error_codes() ==
               ~w(bad_json bad_request unknown_type unauthorized protocol_mismatch
                  unknown_league upstream_unavailable internal)a

      for code <- Envelope.error_codes(), do: assert(is_binary(Envelope.error(code, "m", nil)))
    end
  end
end
