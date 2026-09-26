defmodule Atoll.OAuth.BrowserConsent do
  @moduledoc "Bounded browser consent context, account hints and validated callback construction."
  alias Atoll.OAuth.{PAR, PushedRequest, PKCE}

  def start(client_id, uri) do
    with {:ok, _} <- PAR.get(client_id, uri) do
      {:ok, %{"uri" => uri, "client" => hash(client_id), "view" => random()}}
    end
  end

  def load(%{"uri" => "urn:ietf:params:oauth:request_uri:" <> value = uri, "client" => client}) do
    with true <- PKCE.challenge?(value),
         %PushedRequest{} = request <-
           Atoll.Repo.get(PushedRequest, :crypto.hash(:sha256, uri), log: false),
         true <- hash(request.client_id) == client,
         {:ok, request} <- PAR.get(request.client_id, uri) do
      {:ok, request}
    else
      _ -> {:error, :invalid_request_uri}
    end
  end

  def load(_), do: {:error, :invalid_request_uri}

  def account_matches(request, did) do
    case request.parameters["login_hint"] do
      nil ->
        :ok

      ^did ->
        :ok

      hint ->
        if Atoll.Syntax.handle?(hint) do
          opts =
            Application.get_env(:atoll, :identity_resolution_options, [])
            |> Keyword.put(:force_refresh, true)

          case Atoll.Identity.Handle.verify(hint, opts) do
            {:ok, %{did: ^did}} -> :ok
            _ -> {:error, :account_mismatch}
          end
        else
          {:error, :account_mismatch}
        end
    end
  end

  def callback(result) do
    uri = URI.parse(result.redirect_uri)

    existing =
      URI.query_decoder(uri.query || "")
      |> Enum.reject(fn {key, _} ->
        key in ~w(code state iss error error_description error_uri)
      end)

    fields =
      result
      |> Map.take([:code, :error, :state, :iss])
      |> Enum.map(fn {k, v} -> {Atom.to_string(k), v} end)

    URI.to_string(%{uri | query: URI.encode_query(existing ++ fields)})
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false)
  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
end
