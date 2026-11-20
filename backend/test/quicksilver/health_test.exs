defmodule Quicksilver.HealthTest do
  # CON-3: per-source status, rate-limit state and cache age.
  use ExUnit.Case, async: true

  alias Quicksilver.Health

  setup do
    name = :"health_#{System.unique_integer([:positive])}"
    start_supervised!({Health, name: name})
    %{health: name}
  end

  test "Week 2 sources start idle, in PROTOCOL order", %{health: h} do
    assert %{uptime_s: up, sources: sources} = Health.payload(h)
    assert is_integer(up)
    assert Enum.map(sources, & &1.name) == ["poe_ninja", "trade_leagues"]
    assert Enum.all?(sources, &(&1.status == "idle"))
  end

  test "report merges attributes and keeps the rest", %{health: h} do
    Health.report(h, :poe_ninja, status: :degraded, detail: "HTTP 503")
    Health.report(h, "poe_ninja", %{status: :down})

    [ninja | _] = Health.snapshot(h)
    assert ninja.status == :down
    assert ninja.detail == "HTTP 503"
  end

  test "status :ok sets last_success to now unless given", %{health: h} do
    Health.report(h, :poe_ninja, status: :ok)
    [ninja | _] = Health.snapshot(h)
    assert DateTime.diff(DateTime.utc_now(), ninja.last_success) in 0..1

    given = ~U[2026-11-19 21:00:00.000Z]
    Health.report(h, :trade_leagues, status: :ok, last_success: given)
    [_, leagues] = Health.snapshot(h)
    assert leagues.last_success == given
  end

  test "payload formats timestamps and computes cache age", %{health: h} do
    Health.report(h, :poe_ninja,
      status: :ok,
      last_success: ~U[2026-11-19 21:00:00Z],
      cached_at: DateTime.add(DateTime.utc_now(), -10, :second)
    )

    [ninja | _] = Health.payload(h).sources
    assert ninja.last_success == "2026-11-19T21:00:00.000Z"
    assert ninja.cache_age_s in 10..11
  end

  test "new sources are ordered by PROTOCOL, then by registration", %{health: h} do
    Health.report(h, :custom_source, status: :ok)
    Health.report(h, :client_log, status: :idle)
    Health.register(h, :trade_api)
    Health.register(h, :poe_ninja)

    assert Enum.map(Health.snapshot(h), & &1.name) ==
             ~w(poe_ninja trade_leagues trade_api client_log custom_source)
  end

  test "rate_limit is exposed in wire shape", %{health: h} do
    until = ~U[2026-11-19 21:05:00.5Z]

    Health.report(h, :trade_api,
      rate_limit: [policy: "trade-search-request-limit", queued: 3, restricted_until: until]
    )

    trade = Enum.find(Health.payload(h).sources, &(&1.name == "trade_api"))

    assert trade.rate_limit == %{
             policy: "trade-search-request-limit",
             queued: 3,
             restricted_until: "2026-11-19T21:05:00.500Z"
           }
  end

  test "invalid reports raise in the caller and don't touch the server", %{health: h} do
    assert_raise ArgumentError, fn -> Health.report(h, :poe_ninja, status: :great) end
    assert_raise ArgumentError, fn -> Health.report(h, :poe_ninja, bogus: 1) end
    assert_raise ArgumentError, fn -> Health.report(h, "Bad Name", status: :ok) end
    assert_raise ArgumentError, fn -> Health.report(h, :poe_ninja, last_success: "today") end
    assert_raise ArgumentError, fn -> Health.report(h, :poe_ninja, rate_limit: %{policy: "p"}) end
    assert_raise ArgumentError, fn -> Health.report(h, :poe_ninja, detail: :x) end

    assert Enum.all?(Health.snapshot(h), &(&1.status == :idle))
  end

  test "report to a server that isn't running returns :ok" do
    assert :ok = Health.report(:no_such_health_server, :poe_ninja, status: :ok)
  end
end
