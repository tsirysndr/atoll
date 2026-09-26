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
      Atoll.Accounts.SessionLimiter,
      {DNSCluster, query: Application.get_env(:atoll, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Atoll.PubSub},
      # Start to serve requests, typically the last entry
      AtollWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Atoll.Supervisor]

    refresh_children =
      if Application.get_env(:atoll, :identity_refresh_enabled, false) do
        [
          Supervisor.child_spec({Task.Supervisor, name: Atoll.Identity.TaskSupervisor},
            id: Atoll.Identity.TaskSupervisor
          ),
          {Atoll.Identity.RefreshWorker, []}
        ]
      else
        []
      end

    cleanup_children =
      if Application.get_env(:atoll, :blob_cleanup_enabled, false) do
        [
          Supervisor.child_spec({Task.Supervisor, name: Atoll.Blobs.TaskSupervisor},
            id: Atoll.Blobs.TaskSupervisor
          ),
          {Atoll.Blobs.CleanupWorker, []}
        ]
      else
        []
      end

    Supervisor.start_link(children ++ refresh_children ++ cleanup_children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AtollWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
