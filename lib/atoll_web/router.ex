defmodule AtollWeb.Router do
  use AtollWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AtollWeb do
    get "/", HomeController, :show
  end

  scope "/api", AtollWeb do
    pipe_through :api
  end

  scope "/", AtollWeb do
    pipe_through :api

    get "/health", HealthController, :show
    get "/health/ready", HealthController, :ready
  end

  scope "/xrpc", AtollWeb do
    pipe_through :api

    get "/com.atproto.server.describeServer", ServerController, :describe
    post "/com.atproto.server.createSession", SessionController, :create
    get "/com.atproto.server.getSession", SessionController, :show
    get "/com.atproto.server.checkAccountStatus", SessionController, :status
    post "/com.atproto.server.refreshSession", SessionController, :refresh
    post "/com.atproto.server.deleteSession", SessionController, :delete
    get "/com.atproto.identity.resolveHandle", IdentityController, :resolve_handle
    get "/com.atproto.repo.getRecord", RepoController, :get_record
    post "/com.atproto.repo.uploadBlob", BlobController, :upload
    get "/com.atproto.repo.listMissingBlobs", BlobController, :list_missing
    post "/com.atproto.repo.createRecord", RecordWriteController, :create
    post "/com.atproto.repo.putRecord", RecordWriteController, :put
    post "/com.atproto.repo.deleteRecord", RecordWriteController, :delete
    post "/com.atproto.repo.applyWrites", RecordWriteController, :batch
    post "/com.atproto.repo.importRepo", RepoImportController, :create
    get "/com.atproto.repo.describeRepo", RepoController, :describe
    get "/com.atproto.repo.listRecords", RepoController, :list_records
    get "/com.atproto.sync.getLatestCommit", SyncController, :latest_commit
    get "/com.atproto.sync.getRepoStatus", SyncController, :repo_status
    get "/com.atproto.sync.listRepos", SyncController, :list_repos
    get "/com.atproto.sync.listBlobs", BlobController, :list_blobs
  end

  scope "/xrpc", AtollWeb do
    get "/com.atproto.sync.getRepo", RepoController, :get_repo
    get "/com.atproto.sync.getRecord", SyncController, :get_record
    get "/com.atproto.sync.getBlocks", SyncController, :get_blocks
    get "/com.atproto.sync.getBlob", BlobController, :get_blob
  end
end
