defmodule AtollWeb.ServerController do
  use AtollWeb, :controller

  def identity(conn, _params) do
    conn = put_resp_header(conn, "access-control-allow-origin", "*")

    case Atoll.Identity.Server.document(String.downcase(conn.host)) do
      {:ok, document} ->
        conn
        |> put_resp_header("cache-control", "public, max-age=300")
        |> put_resp_content_type("application/did+ld+json")
        |> send_resp(200, Jason.encode!(document))

      {:error, :not_found} ->
        conn |> put_resp_header("cache-control", "no-store") |> send_resp(404, "Not found")

      {:error, _} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(503, "Server identity is not configured")
    end
  end

  @doc "Caddy on-demand TLS ask endpoint, mirroring the reference PDS's /tls-check."
  def tls_check(conn, params) do
    domain = params["domain"]
    conn = put_resp_header(conn, "cache-control", "no-store")

    approved =
      is_binary(domain) and byte_size(domain) <= 253 and
        (String.downcase(domain) == URI.parse(AtollWeb.Endpoint.url()).host or
           handle_host?(String.downcase(domain)))

    if approved, do: send_resp(conn, 200, ""), else: send_resp(conn, 404, "")
  end

  defp handle_host?(domain) do
    Atoll.Accounts.Signup.hosted_handle?(domain) and
      case Atoll.Repo.get_by(Atoll.Accounts.Profile, handle: domain) do
        %{did: did} ->
          not Atoll.Accounts.Signup.pending?(did)

        # A delegate's account needs a certificate here as well, because this
        # server is what the handle's wildcard resolves to.
        nil ->
          match?({:ok, _}, Atoll.Identity.Delegates.resolve(domain))
      end
  end

  def describe(conn, _params) do
    config = Application.fetch_env!(:atoll, :pds)

    links =
      %{
        privacyPolicy: Keyword.get(config, :privacy_policy_url),
        termsOfService: Keyword.get(config, :terms_of_service_url)
      }
      |> Map.reject(fn {_, value} -> is_nil(value) end)

    result = %{
      did: Keyword.fetch!(config, :did),
      availableUserDomains: Keyword.fetch!(config, :available_user_domains),
      blobUploadLimit: Atoll.Blobs.max_size(),
      inviteCodeRequired: Atoll.Accounts.Invites.required?()
    }

    result = if links == %{}, do: result, else: Map.put(result, :links, links)

    result =
      case Keyword.get(config, :contact_email) do
        nil -> result
        email -> Map.put(result, :contact, %{email: email})
      end

    json(conn, result)
  end
end
