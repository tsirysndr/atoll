defmodule Mix.Tasks.Atoll.Relays.RequestCrawl do
  use Mix.Task
  @shortdoc "Requests configured relays to crawl this PDS"
  @moduledoc """
  Announces the configured HTTPS PDS hostname to ATOLL_RELAY_URLS.

      mix atoll.relays.request_crawl

  This sends network requests. Relay acceptance does not prove that crawling has begun.
  No automatic retry or redirect is performed. Prints per-relay outcomes as JSON.
  """
  def run([]) do
    Mix.Task.run("app.start")

    case Atoll.Relays.request_crawl(Application.get_env(:atoll, :relay_request_options, [])) do
      {:ok, results} ->
        Mix.shell().info(Jason.encode!(%{relays: results}))

        unless Enum.all?(results, &(&1.outcome == :accepted)),
          do: Mix.raise("One or more relays did not accept the crawl request.")

      {:error, _} ->
        Mix.raise(
          "Configure relay origins and a public HTTPS PDS hostname before requesting a crawl."
        )
    end
  end

  def run(_), do: Mix.raise("Usage: mix atoll.relays.request_crawl")
end
