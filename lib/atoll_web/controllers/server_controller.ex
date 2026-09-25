defmodule AtollWeb.ServerController do
  use AtollWeb, :controller

  def describe(conn, _params) do
    config = Application.fetch_env!(:atoll, :pds)

    json(conn, %{
      did: Keyword.fetch!(config, :did),
      availableUserDomains: Keyword.fetch!(config, :available_user_domains)
    })
  end
end
