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
  end

  scope "/xrpc", AtollWeb do
    pipe_through :api

    get "/com.atproto.server.describeServer", ServerController, :describe
    get "/com.atproto.repo.getRecord", RepoController, :get_record
    get "/com.atproto.repo.listRecords", RepoController, :list_records
  end

  scope "/xrpc", AtollWeb do
    get "/com.atproto.sync.getRepo", RepoController, :get_repo
  end
end
