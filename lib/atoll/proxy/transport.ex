defmodule Atoll.Proxy.Transport do
  @moduledoc """
  Bounded XRPC transport to a prepared public destination, without DNS re-resolution.

  Takes a freshly issued service JWT, never the caller's access token. This module
  does not authenticate users; its caller owns admission, rate limits and the final
  authorization recheck. The optional Req request is trusted test configuration.
  """
  alias Atoll.{Identity.Resolver, Proxy.Target, Syntax}

  @request_headers ~w(accept accept-language content-type atproto-accept-labelers)
  @response_headers ~w(content-type content-language atproto-content-labelers atproto-repo-rev retry-after ratelimit-limit ratelimit-remaining ratelimit-reset)
  @max_response 8 * 1024 * 1024
  @max_request 2 * 1024 * 1024

  def send(target, method, nsid, query, headers, body, jwt, opts \\ [])

  def send(%Target{} = target, method, nsid, query, headers, body, jwt, opts)
      when method in [:get, :post] and is_binary(query) and byte_size(query) <= 8192 and
             is_list(headers) and is_binary(body) and byte_size(body) <= @max_request and
             (is_nil(jwt) or (is_binary(jwt) and byte_size(jwt) in 1..8192)) do
    with true <- Syntax.nsid?(nsid) and Resolver.public_address?(target.address),
         true <- method == :post or body == "",
         false <- Regex.match?(~r/[\x00-\x20\x7f#]/, query),
         false <- is_binary(jwt) and Regex.match?(~r/[\x00-\x20\x7f]/, jwt),
         {:ok, headers} <- request_headers(headers) do
      request(target, method, nsid, query, headers, body, jwt, opts)
    else
      _ -> {:error, :invalid_proxy_request}
    end
  end

  def send(_, _, _, _, _, _, _, _), do: {:error, :invalid_proxy_request}

  defp request(target, method, nsid, query, headers, body, jwt, opts) do
    uri = target.uri
    address = target.address
    host = if String.contains?(uri.host, ":"), do: "[#{uri.host}]", else: uri.host
    authority = if uri.port == 443, do: host, else: "#{host}:#{uri.port}"

    url =
      %{
        uri
        | host: to_string(:inet.ntoa(address)),
          path: "/xrpc/" <> nsid,
          query: if(query == "", do: nil, else: query)
      }
      |> URI.to_string()

    result =
      Req.request(Keyword.get_lazy(opts, :request, &Req.new/0),
        method: method,
        url: url,
        body: body,
        headers:
          headers ++
            if(jwt, do: [{"authorization", "Bearer " <> jwt}], else: []) ++
            [
              {"host", authority},
              {"accept-encoding", "identity"}
            ],
        redirect: false,
        retry: false,
        raw: true,
        compressed: false,
        connect_options: [
          hostname: uri.host,
          timeout: 3000,
          transport_opts: [inet6: tuple_size(address) == 8, inet4: tuple_size(address) == 4]
        ],
        receive_timeout: 10_000,
        request_timeout: 15_000,
        into: &collect/2
      )

    case result do
      {:ok, %{body: :too_large}} ->
        {:error, :proxy_response_too_large}

      {:ok, %{status: status} = response} when status in 200..299 or status in 400..599 ->
        if Map.get(response.headers, "content-encoding", []) in [[], ["identity"]] do
          chunks = Req.Response.get_private(response, :proxy_chunks, [])

          {:ok,
           %{
             status: status,
             headers: Map.take(response.headers, @response_headers),
             body: chunks |> Enum.reverse() |> IO.iodata_to_binary()
           }}
        else
          {:error, :proxy_content_encoding}
        end

      {:ok, _} ->
        {:error, :proxy_response_status}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :proxy_timeout}

      {:error, _} ->
        {:error, :proxy_unavailable}
    end
  end

  defp request_headers(headers) when length(headers) <= 64 do
    Enum.reduce_while(headers, {:ok, []}, fn
      {name, value}, {:ok, acc}
      when is_binary(name) and is_binary(value) and byte_size(value) <= 8192 ->
        name = String.downcase(name)

        cond do
          name not in @request_headers -> {:cont, {:ok, acc}}
          Regex.match?(~r/[\x00-\x1f\x7f]/, value) -> {:halt, {:error, :invalid_proxy_request}}
          List.keymember?(acc, name, 0) -> {:halt, {:error, :invalid_proxy_request}}
          true -> {:cont, {:ok, [{name, value} | acc]}}
        end

      _, _ ->
        {:halt, {:error, :invalid_proxy_request}}
    end)
  end

  defp request_headers(_), do: {:error, :invalid_proxy_request}

  defp collect({:data, chunk}, {request, response}) do
    size = Req.Response.get_private(response, :proxy_size, 0) + byte_size(chunk)

    if size > @max_response do
      {:halt, {request, %{response | body: :too_large}}}
    else
      response =
        response
        |> Req.Response.put_private(:proxy_size, size)
        |> Req.Response.update_private(:proxy_chunks, [chunk], &[chunk | &1])

      {:cont, {request, response}}
    end
  end
end
