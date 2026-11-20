defmodule Quicksilver.Integrations.RateLimiterTest do
  # NFR-API-1 (zero 429s), DATA_SOURCES "Client behaviour": limits from headers,
  # queue instead of drop, pause on restriction / 429.
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Quicksilver.Integrations.RateLimiter
  alias Quicksilver.Integrations.RateLimiter.Headers

  # Observed 2026-11-15 (example only; the limiter has no built-in numbers).
  @search_headers [
    {"x-rate-limit-policy", "trade-search-request-limit"},
    {"x-rate-limit-rules", "Ip"},
    {"x-rate-limit-ip", "5:10:60,15:60:300,30:300:1800"},
    {"x-rate-limit-ip-state", "1:10:0,1:60:0,1:300:0"}
  ]

  setup do
    {:ok, clock} = Agent.start_link(fn -> 1_000_000 end)
    health = start_supervised!({Quicksilver.Health, name: nil, sources: []})

    limiter =
      start_supervised!(
        {RateLimiter,
         name: nil,
         clock: fn -> Agent.get(clock, & &1) end,
         margin_ms: 0,
         fallback_429_pause_s: 60,
         health: health,
         health_sources: %{search: :trade_api}}
      )

    %{limiter: limiter, clock: clock, health: health}
  end

  defp advance(%{clock: c, limiter: l}, ms) do
    Agent.update(c, &(&1 + ms))
    RateLimiter.tick(l)
  end

  # release/3 is a cast; wait until it's processed so a later clock advance
  # can't overtake it.
  defp release!(l, ticket, outcome) do
    RateLimiter.release(l, ticket, outcome)
    _ = :sys.get_state(l)
    :ok
  end

  defp acquire_async(l, bucket), do: Task.async(fn -> RateLimiter.acquire(l, bucket) end)

  defp granted?(task, wait \\ 50), do: match?({:ok, {:ok, _}}, Task.yield(task, wait))

  defp rl_headers(tiers, state) do
    [
      {"x-rate-limit-policy", "p"},
      {"x-rate-limit-rules", "Ip"},
      {"x-rate-limit-ip", tiers},
      {"x-rate-limit-ip-state", state}
    ]
  end

  test "parses GGG headers" do
    assert %{policy: "trade-search-request-limit", rules: [rule]} = Headers.parse(@search_headers)
    assert rule.name == "Ip"
    assert hd(rule.tiers) == %{max: 5, period_s: 10, restriction_s: 60}
    assert length(rule.tiers) == 3
    assert hd(rule.state) == %{current: 1, period_s: 10, active_s: 0}
    assert Headers.parse([{"cache-control", "max-age=1"}]) == nil
    assert Headers.retry_after_s([{"Retry-After", "17"}]) == 17
  end

  test "cold start: one request in flight per bucket until headers are seen", %{limiter: l} do
    {:ok, t1} = RateLimiter.acquire(l, :search)
    second = acquire_async(l, :search)
    refute granted?(second)
    assert %{queued: 1, in_flight: 1, policy: nil} = RateLimiter.status(l, :search)

    # Other buckets are independent.
    assert {:ok, _} = RateLimiter.acquire(l, :other)

    release!(l, t1, :error)
    assert granted?(second, 500)
  end

  test "queues when a learned tier is full, and sends when the window moves", ctx do
    l = ctx.limiter
    {:ok, t} = RateLimiter.acquire(l, :b)
    # 2 hits per 10 s; the server already counts our first request.
    release!(l, t, {:response, 200, rl_headers("2:10:60", "1:10:0")})

    assert {:ok, _} = RateLimiter.acquire(l, :b)
    third = acquire_async(l, :b)
    refute granted?(third)
    assert %{queued: 1, policy: "p"} = RateLimiter.status(l, :b)

    advance(ctx, 9_999)
    refute granted?(third)
    advance(ctx, 2)
    assert granted?(third, 500)
  end

  test "resyncs from the -State header when the server counts more hits", ctx do
    l = ctx.limiter
    {:ok, t} = RateLimiter.acquire(l, :b)
    # Server says the window is already full (another tool on this IP?).
    release!(l, t, {:response, 200, rl_headers("3:10:60", "3:10:0")})

    next = acquire_async(l, :b)
    refute granted?(next)
    advance(ctx, 10_001)
    assert granted?(next, 500)
  end

  test "buckets that share a policy share its budget", ctx do
    l = ctx.limiter
    {:ok, t} = RateLimiter.acquire(l, :a)
    release!(l, t, {:response, 200, rl_headers("2:10:60", "1:10:0")})
    {:ok, t} = RateLimiter.acquire(l, :b)
    release!(l, t, {:response, 200, rl_headers("2:10:60", "2:10:0")})

    blocked = acquire_async(l, :a)
    refute granted?(blocked)
  end

  test "an active restriction pauses the policy for its duration", ctx do
    l = ctx.limiter
    {:ok, t} = RateLimiter.acquire(l, :b)
    release!(l, t, {:response, 200, rl_headers("5:10:60", "1:10:30")})

    next = acquire_async(l, :b)
    refute granted?(next)
    assert %{restricted_until: %DateTime{}} = RateLimiter.status(l, :b)
    advance(ctx, 29_000)
    refute granted?(next)
    advance(ctx, 1_001)
    assert granted?(next, 500)
  end

  test "429 pauses for max(Retry-After, active restriction), then resumes", ctx do
    l = ctx.limiter
    {:ok, t} = RateLimiter.acquire(l, :b)
    headers = rl_headers("5:10:60", "6:10:60") ++ [{"retry-after", "20"}]
    release!(l, t, {:response, 429, headers})

    next = acquire_async(l, :b)
    advance(ctx, 59_000)
    refute granted?(next)
    advance(ctx, 1_001)
    assert granted?(next, 500)
  end

  test "429 without any headers pauses the bucket for the fallback back-off", ctx do
    l = ctx.limiter
    {:ok, t} = RateLimiter.acquire(l, :ninja)
    release!(l, t, {:response, 429, []})

    next = acquire_async(l, :ninja)
    refute granted?(next)
    advance(ctx, 60_001)
    assert granted?(next, 500)
  end

  test "a caller that dies while holding a slot releases it", %{limiter: l} do
    holder = spawn(fn -> RateLimiter.acquire(l, :b) && Process.sleep(:infinity) end)
    Process.sleep(20)
    assert %{in_flight: 1} = RateLimiter.status(l, :b)
    Process.exit(holder, :kill)
    assert {:ok, _} = RateLimiter.acquire(l, :b)
  end

  test "reports policy, queue length and restriction to Health", ctx do
    l = ctx.limiter
    {:ok, t} = RateLimiter.acquire(l, :search)
    release!(l, t, {:response, 200, @search_headers})
    Process.sleep(20)

    assert [%{name: "trade_api", rate_limit: rl}] = Quicksilver.Health.snapshot(ctx.health)
    assert rl == %{policy: "trade-search-request-limit", queued: 0, restricted_until: nil}
  end
end
