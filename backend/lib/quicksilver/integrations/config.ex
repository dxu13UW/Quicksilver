defmodule Quicksilver.Integrations.Config do
  @moduledoc """
  Settings for the integrations subtree.

  Read from `config :quicksilver, Quicksilver.Integrations, [...]`, over these
  defaults:

  | key | default | meaning |
  |---|---|---|
  | `:http_adapter` | `HTTP.MintAdapter` (`HTTP.Disabled` in the test env) | transport, see `Quicksilver.Integrations.HTTP` |
  | `:auto_refresh` | `true` (`false` in the test env) | fetch at startup and on the refresh schedule |
  | `:poe_ninja_types` | `[{:exchange, "Currency"}, {:stash, "UniqueAccessory"}]` | poe.ninja overviews kept fresh for the current league. `Currency` must stay first: it feeds `rates.update`. |

  TTLs are documented in DATA_SOURCES.md "Caching policy" and set in
  `Quicksilver.Integrations.Leagues` / `Quicksilver.Integrations.PoeNinja`
  (each takes them as start options too).

  **Test env.** The defaults differ in the test env (decided at compile time,
  because `config/` belongs to the backend lane) so that `mix test` can never
  reach the network and the application's own integrations processes stay
  `idle`. Tests start private instances with a fixture adapter.

  **`QUICKSILVER_OFFLINE=1`** (dev/test only) forces `HTTP.Disabled` and
  `auto_refresh: false` in any env, e.g. for end-to-end tests that boot
  `mix run`.
  """

  alias Quicksilver.Integrations.HTTP

  @test_env Mix.env() == :test

  @defaults [
    http_adapter: if(@test_env, do: HTTP.Disabled, else: HTTP.MintAdapter),
    auto_refresh: not @test_env,
    poe_ninja_types: [{:exchange, "Currency"}, {:stash, "UniqueAccessory"}]
  ]

  @doc "All settings, merged and with the offline override applied."
  @spec all() :: keyword()
  def all do
    config =
      Keyword.merge(@defaults, Application.get_env(:quicksilver, Quicksilver.Integrations, []))

    if offline?(),
      do: Keyword.merge(config, http_adapter: HTTP.Disabled, auto_refresh: false),
      else: config
  end

  @doc "One setting."
  @spec get(atom()) :: term()
  def get(key), do: Keyword.fetch!(all(), key)

  @doc "The configured HTTP adapter."
  @spec http_adapter() :: HTTP.adapter()
  def http_adapter, do: get(:http_adapter)

  @doc "True when `QUICKSILVER_OFFLINE` is `1` or `true`."
  @spec offline?() :: boolean()
  def offline?, do: System.get_env("QUICKSILVER_OFFLINE") in ["1", "true"]
end
