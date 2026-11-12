defmodule Atoll.Accounts.Turnstile do
  @moduledoc "Server-side Turnstile verification for public registration."
  @endpoint "https://challenges.cloudflare.com/turnstile/v0/siteverify"

  def config_from_env!(env) do
    site = present(env["ATOLL_TURNSTILE_SITE_KEY"])
    secret = present(env["ATOLL_TURNSTILE_SECRET_KEY"])

    hosts =
      String.split(env["ATOLL_TURNSTILE_HOSTNAMES"] || "", ",", trim: true)
      |> Enum.map(&String.trim/1)

    if is_nil(site) != is_nil(secret),
      do: raise("Set both ATOLL_TURNSTILE_SITE_KEY and ATOLL_TURNSTILE_SECRET_KEY")

    unless Enum.all?(hosts, &Atoll.Syntax.handle?/1),
      do: raise("ATOLL_TURNSTILE_HOSTNAMES must contain DNS hostnames")

    [site_key: site, secret_key: secret, hostnames: hosts]
  end

  def description do
    case config()[:site_key] do
      nil -> nil
      key -> %{siteKey: key, action: "signup"}
    end
  end

  def verify(token) do
    case config()[:secret_key] do
      nil -> :ok
      secret -> verify_token(token, secret)
    end
  end

  defp verify_token(token, secret) when is_binary(token) and byte_size(token) in 1..2048 do
    options = [
      url: @endpoint,
      json: %{secret: secret, response: token},
      retry: false,
      redirect: false,
      receive_timeout: 5_000,
      connect_options: [timeout: 5_000]
    ]

    case Req.post(
           Keyword.merge(options, Application.get_env(:atoll, :turnstile_request_options, []))
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        hosts = config()[:hostnames] || []
        hosts = if hosts == [], do: [URI.parse(AtollWeb.Endpoint.url()).host], else: hosts

        if body["success"] == true and body["action"] == "signup" and body["hostname"] in hosts,
          do: :ok,
          else: {:error, :turnstile_failed}

      _ ->
        {:error, :turnstile_unavailable}
    end
  end

  defp verify_token(_, _), do: {:error, :turnstile_failed}
  defp config, do: Application.get_env(:atoll, :turnstile, [])
  defp present(nil), do: nil

  defp present(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end
end
