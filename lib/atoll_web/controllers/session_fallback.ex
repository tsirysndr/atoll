defmodule AtollWeb.SessionFallback do
  use AtollWeb, :controller

  def call(conn, {:error, {:repo_inactive, :takendown}}) do
    conn
    |> put_status(400)
    |> json(%{error: "AccountTakedown", message: "Account is taken down."})
  end

  def call(conn, error), do: AtollWeb.XRPCFallback.call(conn, error)
end
