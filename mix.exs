defmodule MyApp.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/example/my_app"

  def project do
    [
      app: :my_app,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # Compiler options: treat warnings as errors in test/dev to keep code clean
      elixirc_options: [warnings_as_errors: Mix.env() != :prod],
      deps: deps(),

      # Docs
      name: "MyApp",
      source_url: @source_url,
      docs: docs(),

      # Test coverage
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],

      # Dialyzer static analysis
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix, :ex_unit]
      ],

      # Package info for Hex publishing
      package: package(),
      description: description()
    ]
  end

  # OTP application configuration.
  # `mod` starts the application supervisor when the app boots.
  def application do
    [
      mod: {MyApp.Application, []},
      extra_applications: extra_applications(Mix.env())
    ]
  end

  # Only compile support/test helper files in the :test environment
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Extra OTP applications required at runtime.
  # :logger is always needed; :observer/:wx are handy in dev for introspection.
  defp extra_applications(:dev), do: [:logger, :runtime_tools, :observer, :wx]
  defp extra_applications(_), do: [:logger, :runtime_tools]

  # Project dependencies.
  # Only runtime deps are compiled in prod releases; dev/test-only deps are excluded.
  defp deps do
    [
      # --- Core / runtime dependencies ---
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      {:plug_cowboy, "~> 2.7"},
      {:phoenix, "~> 1.7"},
      {:phoenix_pubsub, "~> 2.1"},
      {:ecto_sql, "~> 3.11"},
      {:postgrex, "~> 0.17"},
      {:finch, "~> 0.18"},
      {:req, "~> 0.4"},

      # --- Dev / test only dependencies ---
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:mox, "~> 1.1", only: :test},
      {:faker, "~> 0.18", only: :test}
    ]
  end

  # Package metadata used when publishing to Hex.pm
  defp package do
    [
      maintainers: ["Example Team"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end

  # ExDoc configuration for generated documentation
  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end

  defp description do
    "A production-ready Elixir application demonstrating best practices for mix.exs configuration."
  end
end
