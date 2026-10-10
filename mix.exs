defmodule Relay.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/e-suiss/relay"

  def project do
    [
      app: :relay,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:boundary] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      package: package(),
      name: "Relay",
      source_url: @source_url,
      docs: docs(),
      dialyzer: dialyzer(),
      releases: releases(),
      test_coverage: [summary: false]
    ]
  end

  def application do
    [
      mod: {Relay.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto]
    ]
  end

  def cli do
    [preferred_envs: [check: :test, "relay.catalog.check": :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "lib_dev", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "lib_dev"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8.15"},
      {:phoenix_ecto, "~> 4.7"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22.4"},
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},
      {:telemetry_metrics, "~> 1.2"},
      {:telemetry_poller, "~> 1.3"},
      {:logger_json, "~> 7.0"},
      {:tzdata, "~> 1.2.2"},
      {:boundary, "~> 0.11", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.16", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:excellent_migrations, "~> 0.1.10", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.5", only: [:dev, :test]},
      {:stream_data, "~> 1.4", only: [:dev, :test]},
      {:mox, "~> 1.3", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      lint: [
        "relay.lint.sql",
        "relay.lint.comments",
        "relay.lint.claims",
        "relay.lint.images",
        "relay.lint.deps",
        "relay.lint.nif",
        "relay.lint.tests",
        "relay.catalog.check"
      ]
    ]
  end

  defp package do
    [
      name: "esuiss_relay",
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CONTRIBUTING.md", "SECURITY.md", "CODE_OF_CONDUCT.md", "LICENSE"],
      source_ref: "v#{@version}"
    ]
  end

  defp dialyzer do
    [
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      plt_add_apps: [:mix, :ex_unit, :credo],
      flags: [:error_handling, :extra_return, :missing_return]
    ]
  end

  defp releases do
    [
      relay: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent],
        strip_beams: [keep: ["Docs"]]
      ]
    ]
  end
end
