defmodule ScxmlOrchestrator.MixProject do
  use Mix.Project

  def project do
    [
      app: :scxml_orchestrator,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [tool: ExCoveralls, summary: [threshold: 100]],
      preferred_cli_env: [coveralls: :test, "coveralls.detail": :test, "coveralls.html": :test],
      escript: [main_module: ScxmlOrchestrator.Main],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ScxmlOrchestrator.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      # Lightweight OTel API only — the host app (scxml-http-server) brings the
      # SDK + exporter, so spans are no-ops here when no SDK is present.
      {:opentelemetry_api, "~> 1.5"},
      # @decorate with_span(...) auto-instrumentation for the interpreter.
      {:open_telemetry_decorator, "~> 1.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.12", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end
end
