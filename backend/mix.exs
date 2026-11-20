defmodule Quicksilver.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :quicksilver,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Quicksilver.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # External API access is owned by the integrations lane (CLAUDE.md rule 3,
  # docs/DATA_SOURCES.md). Its only HTTP client is `mint`, used solely by
  # `Quicksilver.Integrations.HTTP`; never call it from anywhere else.
  defp deps do
    [
      {:bandit, "~> 1.6"},
      {:websock_adapter, "~> 0.5"},
      {:jason, "~> 1.4"},
      # HTTP client for Quicksilver.Integrations (TLS via OTP's cacerts_get/0).
      {:mint, "~> 1.6"},
      # Test-only WebSocket client used to drive the gateway in tests.
      {:mint_web_socket, "~> 1.0", only: :test}
    ]
  end
end
