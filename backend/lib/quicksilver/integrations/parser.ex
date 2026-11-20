defmodule Quicksilver.Integrations.Parser do
  @moduledoc """
  Pure functions that turn decoded JSON from external sources into our own
  shapes. Shapes are documented in DATA_SOURCES.md "Endpoints"; anything
  unexpected returns `{:error, :bad_shape}` rather than raising.
  """

  @type league :: %{id: String.t(), text: String.t()}
  @type rate_row :: %{
          id: String.t(),
          name: String.t(),
          chaos: float(),
          divine: float(),
          change_7d: float() | nil,
          volume_chaos: float() | nil
        }

  @doc """
  Trade league list → PC leagues in source order. An empty PC list is an error
  (it would leave the selector empty).
  """
  @spec trade_leagues(term()) :: {:ok, [league()]} | {:error, :bad_shape}
  def trade_leagues(%{"result" => result}) when is_list(result) do
    leagues =
      for %{"id" => id, "realm" => "pc"} = l <- result, is_binary(id) do
        %{id: id, text: if(is_binary(l["text"]), do: l["text"], else: id)}
      end

    if leagues == [], do: {:error, :bad_shape}, else: {:ok, leagues}
  end

  def trade_leagues(_), do: {:error, :bad_shape}

  @doc "poe.ninja index-state → names of leagues with economy data."
  @spec ninja_economy_leagues(term()) :: {:ok, [String.t()]} | {:error, :bad_shape}
  def ninja_economy_leagues(%{"economyLeagues" => leagues}) when is_list(leagues),
    do: {:ok, for(%{"name" => n} <- leagues, is_binary(n), do: n)}

  def ninja_economy_leagues(_), do: {:error, :bad_shape}

  @doc """
  poe.ninja exchange overview → `%{divine_chaos: float, rows: [rate_row]}`,
  rows sorted by chaos value, descending.

  * `divine_chaos` is the `divine` line's `primaryValue` when present (so the
    Divine Orb row shows exactly 1.0 divine), else `1 / core.rates.divine`.
  * Names come from `items`, joined on `id`.
  * Empty `lines` means poe.ninja doesn't support the type (verified: unknown
    types return 200 with empty lines): `{:error, :unsupported_type}`.
  """
  @spec exchange_rates(term()) ::
          {:ok, %{divine_chaos: float(), rows: [rate_row()]}}
          | {:error, :unsupported_type | :no_divine_rate | :bad_shape}
  def exchange_rates(%{"lines" => []}), do: {:error, :unsupported_type}

  def exchange_rates(%{"lines" => lines} = body) when is_list(lines) do
    names =
      for %{"id" => id, "name" => name} <- List.wrap(body["items"]), into: %{}, do: {id, name}

    with {:ok, divine_chaos} <- divine_chaos(body, lines) do
      rows =
        for %{"id" => id, "primaryValue" => chaos} = line <- lines,
            is_binary(id),
            is_number(chaos) do
          chaos = chaos * 1.0

          %{
            id: id,
            name: Map.get(names, id, id),
            chaos: chaos,
            divine: chaos / divine_chaos,
            change_7d: number(get_in(line, ["sparkline", "totalChange"])),
            volume_chaos: number(line["volumePrimaryValue"])
          }
        end

      {:ok, %{divine_chaos: divine_chaos, rows: Enum.sort_by(rows, & &1.chaos, :desc)}}
    end
  end

  def exchange_rates(_), do: {:error, :bad_shape}

  defp divine_chaos(body, lines) do
    line = Enum.find(lines, &match?(%{"id" => "divine"}, &1))

    cond do
      is_map(line) and is_number(line["primaryValue"]) and line["primaryValue"] > 0 ->
        {:ok, line["primaryValue"] * 1.0}

      is_number(get_in(body, ["core", "rates", "divine"])) and
          get_in(body, ["core", "rates", "divine"]) > 0 ->
        {:ok, 1.0 / body["core"]["rates"]["divine"]}

      true ->
        {:error, :no_divine_rate}
    end
  end

  @doc """
  poe.ninja stash item overview → item price lines. Empty `lines` means the type
  isn't served here (verified for `Fragment`): `{:error, :unsupported_type}`.
  """
  @spec stash_items(term()) :: {:ok, [map()]} | {:error, :unsupported_type | :bad_shape}
  def stash_items(%{"lines" => []}), do: {:error, :unsupported_type}

  def stash_items(%{"lines" => lines}) when is_list(lines) do
    items =
      for %{"name" => name, "chaosValue" => chaos} = l <- lines,
          is_binary(name),
          is_number(chaos) do
        %{
          name: name,
          base_type: l["baseType"],
          variant: l["variant"],
          links: l["links"],
          item_type: l["itemType"],
          gem_level: l["gemLevel"],
          gem_quality: l["gemQuality"],
          corrupted: l["corrupted"],
          chaos: chaos * 1.0,
          divine: number(l["divineValue"]),
          listing_count: l["listingCount"],
          details_id: l["detailsId"]
        }
      end

    {:ok, items}
  end

  def stash_items(_), do: {:error, :bad_shape}

  defp number(n) when is_number(n), do: n * 1.0
  defp number(_), do: nil
end
