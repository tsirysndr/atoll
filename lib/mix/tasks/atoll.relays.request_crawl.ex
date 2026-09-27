defmodule Mix.Tasks.Atoll.Relays.RequestCrawl do
  use Mix.Task
  @shortdoc "Requests configured relays to crawl this PDS"
  @moduledoc """
  Announces the configured HTTPS PDS hostname to ATOLL_RELAY_URLS.

      mix atoll.relays.request_crawl

  This sends network requests. Relay acceptance does not prove that crawling has begun.
  No automatic retry or redirect is performed. Prints per-relay outcomes as JSON.
  Stores an operator audit attempt before sending and a linked completion after
  the batch. An attempt without completion has an unknown outcome; inspect the
  history before retrying. No database lock is held during network requests.
  """
  def run([]) do
    Mix.Task.run("app.start")

    case Atoll.Relays.request_crawl_audited(
           Application.get_env(:atoll, :relay_request_options, [])
         ) do
      {:ok, results} ->
        Mix.shell().info(Jason.encode!(%{relays: results}))

        unless Enum.all?(results, &(&1.outcome == :accepted)),
          do: Mix.raise("One or more relays did not accept the crawl request.")

      {:error, :relay_audit_unavailable} ->
        Mix.raise("Crawl attempt could not be audited; no relay requests were sent.")

      {:error, :relay_outcome_audit_unavailable} ->
        Mix.raise(
          "Relay requests were sent, but outcomes could not be audited. Inspect the attempt history before retrying."
        )

      {:error, _} ->
        Mix.raise(
          "Configure relay origins and a public HTTPS PDS hostname before requesting a crawl."
        )
    end
  end

  def run(_), do: Mix.raise("Usage: mix atoll.relays.request_crawl")
end
