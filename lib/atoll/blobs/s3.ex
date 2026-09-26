defmodule Atoll.Blobs.S3 do
  @moduledoc "Path-style S3-compatible blob storage using Req's AWS SigV4 signing. Configuration is trusted."
  alias Atoll.CID
  @max_bytes 5 * 1024 * 1024

  def put(cid, bytes, config) do
    case request(:put, cid, bytes, config) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      _ -> {:error, :blob_storage_unavailable}
    end
  end

  def get(cid, config) do
    case request(:get, cid, "", config) do
      {:ok, %{status: 200, body: bytes}} when is_binary(bytes) -> {:ok, bytes}
      _ -> {:error, :blob_storage_unavailable}
    end
  end

  defp request(method, cid, body, config) do
    with {:ok, url, signing} <- options(cid, config) do
      req = Keyword.get(config, :request, Req.new())

      Req.request(req,
        method: method,
        url: url,
        body: body,
        headers: [{"content-type", "application/octet-stream"}],
        aws_sigv4: signing,
        retry: false,
        redirect: false,
        raw: true,
        compressed: false,
        connect_options: [timeout: 3000],
        receive_timeout: 10_000,
        request_timeout: 15_000,
        into: fn {:data, bytes}, {request, response} ->
          previous = response.body || ""

          if byte_size(previous) + byte_size(bytes) <= @max_bytes do
            {:cont, {request, %{response | body: previous <> bytes}}}
          else
            {:halt, {request, %{response | status: 502, body: ""}}}
          end
        end
      )
    end
  end

  defp options(cid, config) when is_list(config) do
    endpoint = Keyword.get(config, :endpoint, "")
    bucket = Keyword.get(config, :bucket, "")
    key = Keyword.get(config, :access_key_id)
    secret = Keyword.get(config, :secret_access_key)
    uri = URI.parse(endpoint)

    if uri.scheme in ["https", "http"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
         uri.path in [nil, "", "/"] and
         Regex.match?(~r/\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z/, bucket) and
         is_binary(key) and key != "" and is_binary(secret) and secret != "" do
      signing = [
        service: :s3,
        region: Keyword.get(config, :region, "us-east-1"),
        access_key_id: key,
        secret_access_key: secret
      ]

      signing =
        if token = Keyword.get(config, :session_token),
          do: Keyword.put(signing, :token, token),
          else: signing

      {:ok,
       String.trim_trailing(endpoint, "/") <> "/" <> bucket <> "/blobs/" <> CID.to_base32(cid),
       signing}
    else
      {:error, :blob_storage_unavailable}
    end
  end

  defp options(_, _), do: {:error, :blob_storage_unavailable}
end
