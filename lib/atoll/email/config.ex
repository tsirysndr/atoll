defmodule Atoll.Email.Config do
  @moduledoc "Validates the external email Worker configuration without exposing secrets."

  def parse!(env) do
    url = env["ATOLL_EMAIL_WORKER_URL"]
    token = env["ATOLL_EMAIL_WORKER_TOKEN"]

    case validate(url, token) do
      :disabled ->
        []

      :ok ->
        [url: url, token: token]

      :error ->
        raise "ATOLL_EMAIL_WORKER_URL and ATOLL_EMAIL_WORKER_TOKEN must configure an HTTPS endpoint and a nonempty bearer token"
    end
  end

  def validate(nil, nil), do: :disabled

  def validate(url, token) when is_binary(url) and is_binary(token) do
    uri = URI.parse(url)

    if uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and is_nil(uri.fragment) and is_nil(uri.query) and
         byte_size(token) in 1..4096 and Regex.match?(~r/\A[\x21-\x7e]+\z/, token),
       do: :ok,
       else: :error
  end

  def validate(_, _), do: :error
end
