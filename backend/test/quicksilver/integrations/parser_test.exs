defmodule Quicksilver.Integrations.ParserTest do
  # DASH-1 (currency rates in chaos and divine), NFR-MNT-1 (recorded responses).
  # Shapes from recorded responses (DATA_SOURCES.md "Endpoints").
  use ExUnit.Case, async: true

  alias Quicksilver.Integrations.{FixtureHTTP, Parser}

  defp body(name), do: name |> FixtureHTTP.load() |> elem(2)

  test "trade leagues: PC only, source order, id + text" do
    assert {:ok, leagues} = Parser.trade_leagues(body("trade_leagues"))
    assert length(leagues) == 8
    assert hd(leagues) == %{id: "Covens", text: "Covens"}
    assert Enum.map(leagues, & &1.id) |> Enum.take(-1) == ["Hardcore Ruthless"]

    assert {:error, :bad_shape} =
             Parser.trade_leagues(%{"result" => [%{"id" => "X", "realm" => "xbox"}]})

    assert {:error, :bad_shape} = Parser.trade_leagues([])
  end

  test "poe.ninja index-state: economy league names" do
    assert {:ok, ["Covens", "Hardcore Covens", "Standard", "Hardcore"]} =
             Parser.ninja_economy_leagues(body("ninja_index_state"))
  end

  test "exchange overview → rate rows" do
    assert {:ok, %{divine_chaos: dc, rows: rows}} =
             Parser.exchange_rates(body("ninja_exchange_currency_covens"))

    assert dc == 216.2
    assert length(rows) == 106
    assert rows == Enum.sort_by(rows, & &1.chaos, :desc)

    divine = Enum.find(rows, &(&1.id == "divine"))
    assert %{name: "Divine Orb", chaos: 216.2, divine: 1.0, change_7d: 245.4} = divine
    assert divine.volume_chaos == 12_321_486.0

    chaos = Enum.find(rows, &(&1.id == "chaos"))
    assert chaos.chaos == 1.0
    assert_in_delta chaos.divine, 1 / 216.2, 1.0e-9
  end

  test "exchange: divine rate falls back to core.rates when there is no divine line" do
    b = body("ninja_exchange_currency_covens")
    b = %{b | "lines" => Enum.reject(b["lines"], &(&1["id"] == "divine"))}
    assert {:ok, %{divine_chaos: dc}} = Parser.exchange_rates(b)
    assert_in_delta dc, 1 / 0.004626, 1.0e-6
  end

  # TP-RATES-013
  test "change_7d and volume_chaos are nil when the line has no sparkline or volume" do
    b = body("ninja_exchange_currency_covens")

    strip = fn
      %{"id" => "chaos"} = l -> Map.drop(l, ["sparkline", "volumePrimaryValue"])
      %{"id" => "mirror"} = l -> %{l | "sparkline" => nil, "volumePrimaryValue" => nil}
      %{"id" => "mirror-shard"} = l -> put_in(l, ["sparkline", "totalChange"], nil)
      l -> l
    end

    assert {:ok, %{rows: rows}} =
             Parser.exchange_rates(%{b | "lines" => Enum.map(b["lines"], strip)})

    row = fn id -> Enum.find(rows, &(&1.id == id)) end

    assert %{chaos: 1.0, change_7d: nil, volume_chaos: nil} = row.("chaos")
    assert %{chaos: 95_564.0, change_7d: nil, volume_chaos: nil} = row.("mirror")
    assert %{change_7d: nil, volume_chaos: v} = row.("mirror-shard")
    assert is_float(v)
    # Untouched rows keep their values.
    assert %{change_7d: 245.4, volume_chaos: 12_321_486.0} = row.("divine")
    # A null row is still JSON-encodable for rates.update.
    assert Jason.encode!(row.("chaos")) =~ ~s("change_7d":null)
  end

  test "empty lines mean an unsupported type, not 'no prices'" do
    assert {:error, :unsupported_type} =
             Parser.exchange_rates(%{"core" => %{}, "lines" => [], "items" => []})

    assert {:error, :unsupported_type} = Parser.stash_items(%{"lines" => []})
    assert {:error, :bad_shape} = Parser.exchange_rates(%{"nope" => 1})
  end

  test "stash item overview → item lines" do
    assert {:ok, [first | _] = items} =
             Parser.stash_items(body("ninja_stash_uniqueaccessory_covens"))

    assert length(items) == 15

    assert %{
             name: "Foulborn Headhunter",
             base_type: "Leather Belt",
             chaos: 263_040.0,
             divine: 1200.0,
             listing_count: 1,
             variant: "Culling Strike, Minimap Icons"
           } = first
  end
end
