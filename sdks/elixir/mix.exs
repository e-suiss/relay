defmodule EsuissRelay.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/e-suiss/relay"

  def project do
    [
      app: :esuiss_relay,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: false,
      deps: deps(),
      package: package(),
      description:
        "Server SDK for Relay, the notification, messaging and agent platform of Suiss.",
      name: "EsuissRelay",
      source_url: @source_url,
      docs: [main: "readme", extras: ["README.md"]],
      dialyzer: dialyzer()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto, :public_key, :ssl, :inets]]
  end

  defp elixirc_paths(:test), do: ["lib", "lib_dev", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "lib_dev"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:yaml_elixir, "~> 2.12.2", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "esuiss_relay",
      licenses: ["Apache-2.0"],
      links: %{"Source" => @source_url},
      files: ~w(lib mix.exs README.md .formatter.exs)
    ]
  end

  defp dialyzer do
    [
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      plt_add_apps: [:mix, :ex_unit, :yaml_elixir],
      flags: [:error_handling, :extra_return, :missing_return]
    ]
  end
end
