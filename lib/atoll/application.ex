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
      {DynamicSupervisor,
       name: Atoll.CAR.StageSupervisor,
       strategy: :one_for_one,
       max_children: Application.get_env(:atoll, :import_concurrency, 16)},
      Atoll.Accounts.SessionLimiter,
      {Atoll.Identity.Cache,
       name: Atoll.Identity.Cache,
       ttl_ms: Application.get_env(:atoll, :did_cache_ttl_seconds, 60) * 1000},
      Supervisor.child_spec(
        {Atoll.Identity.Cache,
         name: Atoll.Identity.HandleCache,
         ttl_ms: Application.get_env(:atoll, :handle_cache_ttl_seconds, 60) * 1000,
         max_entries: 256,
         max_bytes: 1_048_576},
        id: Atoll.Identity.HandleCache
      ),
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

    account_cleanup_children =
      if Application.get_env(:atoll, :account_cleanup_enabled, false) do
        [
          Supervisor.child_spec({Task.Supervisor, name: Atoll.Accounts.CleanupTaskSupervisor},
            id: Atoll.Accounts.CleanupTaskSupervisor
          ),
          {Atoll.Accounts.CleanupWorker, []}
        ]
      else
        []
      end

    relay_children =
      if Application.get_env(:atoll, :relay_crawl_enabled, false) do
        [
          Supervisor.child_spec({Task.Supervisor, name: Atoll.Relays.TaskSupervisor},
            id: Atoll.Relays.TaskSupervisor
          ),
          {Atoll.Relays.Worker, []}
        ]
      else
        []
      end

    retention_children =
      if Application.get_env(:atoll, :event_retention_enabled, false) do
        [
          Supervisor.child_spec(
            {Task.Supervisor, name: Atoll.Repositories.RetentionTaskSupervisor},
            id: Atoll.Repositories.RetentionTaskSupervisor
          ),
          {Atoll.Repositories.EventRetentionWorker, []}
        ]
      else
        []
      end

    Supervisor.start_link(
      Atoll.Redis.children() ++
        children ++
        refresh_children ++
        cleanup_children ++
        account_cleanup_children ++
        relay_children ++
        retention_children ++
        Atoll.Accounts.SignupCleanupWorker.children() ++
        Atoll.Accounts.SignupRetryWorker.children() ++
        Atoll.OAuth.KeyCheckWorker.children(),
      opts
    )
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AtollWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
