defmodule Atoll.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AtollWeb.Telemetry,
      Atoll.Repo,
      {DNSCluster, query: Application.get_env(:atoll, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Atoll.PubSub},
      # Start a worker by calling: Atoll.Worker.start_link(arg)
      # {Atoll.Worker, arg},
      # Start to serve requests, typically the last entry
      AtollWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Atoll.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AtollWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
