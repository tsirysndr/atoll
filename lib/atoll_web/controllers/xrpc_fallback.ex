defmodule AtollWeb.XRPCFallback do
  use AtollWeb, :controller

  def call(conn, {:error, :invalid_request}) do
    error(conn, 400, "InvalidRequest", "Invalid or unsupported query parameters.")
  end

  def call(conn, {:error, :record_not_found}),
    do: error(conn, 400, "RecordNotFound", "Record not found.")

  def call(conn, {:error, :not_found}),
    do: error(conn, 400, "RepoNotFound", "Repository not found.")

  def call(conn, {:error, :car_too_large}),
    do: error(conn, 413, "RepoTooLarge", "Repository exceeds the in-memory export limit.")

  def call(conn, {:error, _}),
    do: error(conn, 500, "InternalServerError", "Unable to read repository data.")

  defp error(conn, status, code, message),
    do: conn |> put_status(status) |> json(%{error: code, message: message})
end
