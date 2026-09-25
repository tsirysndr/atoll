defmodule AtollWeb.Router do
  use AtollWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
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
  end
end
