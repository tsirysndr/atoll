defmodule Atoll.MixProject do
  use Mix.Project

  def project do
    [
      app: :atoll,
      version: "0.1.0",
      # Keep adapter-specific compile_env artifacts separate when switching databases.
      build_path: build_path(),
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # OTLP transport dependencies must start before either SDK initializes exporters.
      releases: [
        atoll: [
          applications: [
            opentelemetry_exporter: :permanent,
            opentelemetry: :permanent,
            opentelemetry_experimental: :permanent
          ]
        ]
      ],
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  defp build_path do
    if System.get_env("ATOLL_DATABASE") in ["sqlite", "sqlite3"],
      do: "_build/sqlite/#{Mix.env()}",
      else: "_build/#{Mix.env()}"
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Atoll.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto, :public_key, :xmerl]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.15"},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:ecto_sqlite3, "~> 0.22"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:opentelemetry_exporter, "~> 1.11"},
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_api, "~> 1.5"},
      {:opentelemetry_api_experimental, "~> 0.6"},
      {:opentelemetry_experimental, "~> 0.6"},
      {:jason, "~> 1.2"},
      {:req, "~> 0.7.4"},
      {:redix, "~> 1.9"},
      {:argon2_elixir, "~> 4.1"},
      {:jose, "~> 1.11"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing"],
      "assets.build": ["tailwind atoll --minify", "atoll.assets"],
      "assets.deploy": ["assets.build", "phx.digest"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "assets.build",
        "test"
      ]
    ]
  end
end
