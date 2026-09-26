defmodule Atoll.Identity.PLC.Client do
  @moduledoc """
  Submits an already persisted genesis operation to a trusted PLC directory.
  A matching latest operation is required even after a successful POST. Callers
  must retain the exact signed operation across retries: signing again changes
  its DID. This client does not persist operations or activate accounts.
  """
  alias Atoll.Identity.PLC.Operation

  @default_directory "https://plc.directory"
  @max_response 65_536

  def directory_from_env!(value) do
    case directory(value || @default_directory) do
      {:ok, url} ->
        url

      _ ->
        raise "ATOLL_PLC_DIRECTORY_URL must be an HTTPS origin without credentials, query or fragment"
    end
  end

  def submit_genesis(did, operation, opts \\ []) do
    with :ok <- Operation.verify_genesis(did, operation),
         {:ok, cid} <- Operation.cid(operation),
         {:ok, origin} <-
           directory(Application.get_env(:atoll, :plc_directory_url, @default_directory)) do
      url = origin <> "/" <> URI.encode(did, &URI.char_unreserved?/1)
      posted = request(:post, url, [json: operation], opts)
      confirm(request(:get, url <> "/log/last", [], opts), posted, did, cid)
    end
  end

  defp confirm({:ok, %{status: 200, body: body} = response}, _posted, did, cid)
       when is_binary(body) do
    with true <- Req.Response.get_header(response, "content-encoding") in [[], ["identity"]],
         {:ok, operation} <- Jason.decode(body),
         {:ok, actual_cid} <- Operation.cid(operation) do
      if actual_cid == cid and Operation.verify_genesis(did, operation) == :ok,
        do: :ok,
        else: {:error, :plc_conflict}
    else
      _ -> {:error, :invalid_plc_response}
    end
  end

  defp confirm({:ok, %{status: 200}}, _, _, _), do: {:error, :invalid_plc_response}

  defp confirm({:ok, %{status: 404}}, {:ok, %{status: status}}, _, _)
       when status in 400..499 and status not in [408, 429],
       do: {:error, :plc_rejected}

  defp confirm(_, _, _, _), do: {:error, :plc_unavailable}

  defp request(method, url, extra, opts) do
    request = [
      method: method,
      url: url,
      headers: [{"accept", "application/json"}, {"accept-encoding", "identity"}],
      redirect: false,
      retry: false,
      raw: true,
      compressed: false,
      connect_options: [timeout: 3_000],
      receive_timeout: 5_000,
      finch: [pool_timeout: 3_000, request_timeout: 10_000],
      into: &collect/2
    ]

    Req.request(request ++ extra ++ Keyword.take(opts, [:plug]))
  end

  defp collect({:data, data}, {request, response}) do
    if byte_size(response.body) + byte_size(data) > @max_response,
      do: {:halt, {request, %{response | body: :too_large}}},
      else: {:cont, {request, %{response | body: response.body <> data}}}
  end

  defp directory(value) when is_binary(value) and byte_size(value) in 1..2048 do
    case URI.new(value) do
      {:ok,
       %URI{
         scheme: "https",
         host: host,
         port: port,
         path: path,
         userinfo: nil,
         query: nil,
         fragment: nil
       }}
      when is_binary(host) and port in 1..65535 and path in [nil, "", "/"] ->
        if Atoll.Syntax.handle?(host),
          do: {:ok, String.trim_trailing(value, "/")},
          else: {:error, :invalid_plc_directory}

      _ ->
        {:error, :invalid_plc_directory}
    end
  end

  defp directory(_), do: {:error, :invalid_plc_directory}
end
