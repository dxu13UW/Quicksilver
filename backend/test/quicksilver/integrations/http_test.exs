defmodule Quicksilver.Integrations.HTTPTest do
  # NFR-API-2 (every request through the client, project User-Agent, gzip),
  # NFR-API-1 (errors, slot release), NFR-API-3 (Cache-Control TTLs),
  # NFR-MNT-1 (offline: fixture adapter, Disabled default). DATA_SOURCES "Rules for every client".
  use Quicksilver.IntegrationsCase, async: true
  @moduletag :capture_log

  alias Quicksilver.Integrations.{CacheControl, HTTP, RateLimiter}
  alias Quicksilver.Integrations.HTTP.Response

  setup do
    limiter = start_supervised!({RateLimiter, name: nil, health: :none})
    %{limiter: limiter}
  end

  defp get(url, adapter, limiter),
    do: HTTP.get_json(url, bucket: :t, adapter: adapter, limiter: limiter)

  test "sends the project User-Agent, JSON accept and gzip on every request", %{limiter: l} do
    a = FixtureHTTP.start(%{Urls.trade_leagues() => {:fixture, "trade_leagues"}})
    assert {:ok, %{"result" => [_ | _]}, %Response{status: 200}} = get(Urls.trade_leagues(), a, l)

    [{"GET", _, headers}] = FixtureHTTP.requests(a)
    ua = Response.header(headers, "user-agent")

    assert ua ==
             "Quicksilver/#{Quicksilver.version()} (contact: https://github.com/dxu13UW/Quicksilver)"

    assert Response.header(headers, "accept-encoding") == "gzip"
    assert Response.header(headers, "accept") == "application/json"
  end

  test "un-gzips gzip bodies", %{limiter: l} do
    body = :zlib.gzip(~s({"ok":true}))
    r = %Response{status: 200, headers: [{"content-encoding", "gzip"}], body: body}
    a = FixtureHTTP.start(%{"https://x.test/" => r})
    assert {:ok, %{"ok" => true}, %Response{body: ~s({"ok":true})}} = get("https://x.test/", a, l)
  end

  test "non-2xx, transport and decode failures are errors with a short description", %{limiter: l} do
    a =
      FixtureHTTP.start(%{
        "https://x.test/404" => %Response{status: 404, body: "nope"},
        "https://x.test/down" => {:error, :econnrefused},
        "https://x.test/html" => %Response{status: 200, body: "<html>"}
      })

    assert {:error, {:http_status, 404} = e1} = get("https://x.test/404", a, l)
    assert {:error, {:transport, :econnrefused} = e2} = get("https://x.test/down", a, l)
    assert {:error, {:decode, _} = e3} = get("https://x.test/html", a, l)
    assert HTTP.describe_error(e1) == "HTTP 404"
    assert HTTP.describe_error(e2) == "network error"
    assert HTTP.describe_error(e3) == "unexpected response"
  end

  test "an unknown URL never reaches the network in tests", %{limiter: l} do
    a = FixtureHTTP.start(%{})
    assert {:error, {:transport, {:no_fixture, _}}} = get("https://example.invalid/", a, l)
  end

  test "the Disabled adapter refuses, and is the default in the test env", %{limiter: l} do
    assert Quicksilver.Integrations.Config.http_adapter() == HTTP.Disabled
    assert {:error, :http_disabled} = HTTP.get_json(Urls.trade_leagues(), bucket: :t, limiter: l)
  end

  test "an adapter that raises releases its rate-limit slot", %{limiter: l} do
    defmodule Boom do
      def request(_, _, _, _, _), do: raise("boom")
    end

    assert {:error, {:transport, _}} = get("https://x.test/", Boom, l)
    assert %{in_flight: 0} = RateLimiter.status(l, :t)
  end

  describe "CacheControl" do
    test "freshness is max-age minus Age, with fallback and floor" do
      h = [{"cache-control", "public, max-age=1800, stale-if-error=86400"}, {"age", "253"}]
      assert CacheControl.ttl_s(h, 1800, 60) == 1547
      assert CacheControl.stale_if_error_s(h, 10) == 86_400

      assert CacheControl.ttl_s([{"cache-control", "no-cache"}], 1800, 60) == 1800
      assert CacheControl.ttl_s([], 1800, 60) == 1800
      assert CacheControl.ttl_s([{"cache-control", "max-age=0"}], 1800, 60) == 1800
      # A CDN copy older than its max-age (seen live: Age 1534, max-age 120).
      assert CacheControl.ttl_s([{"cache-control", "max-age=120"}, {"age", "1534"}], 3600, 60) ==
               60

      assert CacheControl.stale_if_error_s([], 86_400) == 86_400
    end

    test "recorded poe.ninja headers" do
      {_, headers, _} = FixtureHTTP.load("ninja_exchange_currency_covens")

      assert CacheControl.parse(headers) == %{
               max_age: 1800,
               no_cache: false,
               stale_if_error: 86_400,
               age: 253
             }
    end
  end
end
