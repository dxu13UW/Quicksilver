defmodule Quicksilver.SettingsTest do
  # DASH-2 (saved league survives a restart).
  use ExUnit.Case, async: true

  alias Quicksilver.Settings

  @moduletag :tmp_dir

  defp start(dir) do
    name = :"settings_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Settings, name: name, dir: dir}, id: name)
    {name, pid}
  end

  test "round-trips through the file across restarts", %{tmp_dir: dir} do
    {s1, _} = start(dir)
    assert Settings.get(s1, "league", nil) == nil

    assert :ok = Settings.put(s1, "league", "Covens")
    assert :ok = Settings.put(s1, :trade_api_enabled, false)
    assert Settings.get(s1, :league, nil) == "Covens"

    assert Jason.decode!(File.read!(Path.join(dir, "settings.json"))) ==
             %{"league" => "Covens", "trade_api_enabled" => false}

    {s2, _} = start(dir)
    assert Settings.all(s2) == %{"league" => "Covens", "trade_api_enabled" => false}
  end

  test "creates the directory if missing", %{tmp_dir: dir} do
    nested = Path.join([dir, "a", "b"])
    {s, _} = start(nested)
    assert :ok = Settings.put(s, "league", "Standard")
    assert File.exists?(Path.join(nested, "settings.json"))
    assert Settings.path(s) == Path.join(nested, "settings.json")
  end

  test "keeps unknown keys from the file", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "settings.json"), ~s({"from_the_future": [1, 2]}))
    {s, _} = start(dir)
    :ok = Settings.put(s, "league", "Standard")

    assert Jason.decode!(File.read!(Path.join(dir, "settings.json"))) ==
             %{"from_the_future" => [1, 2], "league" => "Standard"}
  end

  test "a corrupt file is moved aside and defaults are used", %{tmp_dir: dir} do
    path = Path.join(dir, "settings.json")
    File.write!(path, "{truncated")

    {s, _} = ExUnit.CaptureLog.with_log(fn -> start(dir) end) |> elem(0)
    assert Settings.all(s) == %{}
    assert File.read!(path <> ".corrupt") == "{truncated"
    refute File.exists?(path)
  end

  test "writes leave no temp files and stale ones are cleaned at start", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "settings.json.tmp-123"), "partial")
    {s, _} = start(dir)
    :ok = Settings.put(s, "league", "Standard")
    assert File.ls!(dir) == ["settings.json"]
  end

  test "a value that can't be encoded is refused and nothing changes", %{tmp_dir: dir} do
    {s, _} = start(dir)
    :ok = Settings.put(s, "league", "Standard")

    {result, _log} =
      ExUnit.CaptureLog.with_log(fn -> Settings.put(s, "league", {:not, :json}) end)

    assert {:error, {:not_json_encodable, _}} = result
    assert Settings.get(s, "league", nil) == "Standard"
    assert Jason.decode!(File.read!(Path.join(dir, "settings.json"))) == %{"league" => "Standard"}
  end

  test "the default directory is the OS user config dir unless overridden" do
    # In the test env the app is pointed away from the real user config.
    assert Settings.default_dir() == Application.get_env(:quicksilver, :settings_dir)
    assert Settings.default_dir() =~ "_build/test/settings"
  end
end
