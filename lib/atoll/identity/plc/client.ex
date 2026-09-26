defmodule Atoll.Identity.PLC.Client do
  @moduledoc """
  Submits already persisted genesis and update operations to a trusted PLC directory.
  A matching latest operation is required even after a successful POST. Callers
  must retain the exact signed operation across retries: signing again changes
  its DID. This client does not persist operations or activate accounts.
  """
  alias Atoll.Identity.PLC.{AuditLog, Operation}

  @default_directory "https://plc.directory"
  @max_response 65_536

  @doc "Fetches and verifies bounded audit evidence, then checks its head against a fresh latest read."
  def fetch_audit(did, opts \\ []) do
    with true <- is_binary(did) and Regex.match?(~r/\Adid:plc:[a-z2-7]{24}\z/, did),
         {:ok, origin} <-
           directory(Application.get_env(:atoll, :plc_directory_url, @default_directory)) do
      url = origin <> "/" <> URI.encode(did, &URI.char_unreserved?/1)

      with {:ok, entries} <-
             audit_body(request(:get, url <> "/log/audit", [], opts, 8 * 1024 * 1024)),
           {:ok, state} <- AuditLog.verify(did, entries),
           {:ok, latest} <- latest_cid(request(:get, url <> "/log/last", [], opts)),
           true <- latest == state.cid do
        {:ok, %{entries: entries, state: state}}
      else
        false -> {:error, :plc_conflict}
        error -> error
      end
    else
      false -> {:error, :invalid_plc_operation}
      error -> error
    end
  end

  defp audit_body({:ok, %{status: 200, body: body} = response}) when is_binary(body) do
    with true <- Req.Response.get_header(response, "content-encoding") in [[], ["identity"]],
         {:ok, entries} when is_list(entries) <- Jason.decode(body) do
      {:ok, entries}
    else
      _ -> {:error, :invalid_plc_response}
    end
  end

  defp audit_body({:ok, %{status: 200}}), do: {:error, :invalid_plc_response}
  defp audit_body(_), do: {:error, :plc_unavailable}

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

  @doc """
  Submits an exact persisted ordinary update against an already trusted predecessor.

  The caller must authenticate the predecessor's chain to this DID, authorize the
  action, and persist the signed operation before calling. This does not implement
  recovery forks. A matching latest operation makes retries read-only; a different
  predecessor fails closed before POST. The directory still arbitrates races.
  """
  def submit_update(did, previous, operation, opts \\ []) do
    with true <- is_binary(did) and Regex.match?(~r/\Adid:plc:[a-z2-7]{24}\z/, did),
         {:ok, _signer} <- Operation.verify_update(previous, operation),
         {:ok, prior_cid} <- Operation.cid(previous),
         {:ok, cid} <- Operation.cid(operation),
         {:ok, origin} <-
           directory(Application.get_env(:atoll, :plc_directory_url, @default_directory)) do
      url = origin <> "/" <> URI.encode(did, &URI.char_unreserved?/1)

      case latest_cid(request(:get, url <> "/log/last", [], opts)) do
        {:ok, ^cid} ->
          :ok

        {:ok, ^prior_cid} ->
          posted = request(:post, url, [json: operation], opts)

          case latest_cid(request(:get, url <> "/log/last", [], opts)) do
            {:ok, ^cid} -> :ok
            {:ok, ^prior_cid} -> update_failure(posted)
            {:ok, _} -> {:error, :plc_conflict}
            error -> error
          end

        {:ok, _} ->
          {:error, :plc_conflict}

        error ->
          error
      end
    else
      false -> {:error, :invalid_plc_operation}
      error -> error
    end
  end

  defp update_failure({:ok, %{status: status}})
       when status in 400..499 and status not in [408, 429],
       do: {:error, :plc_rejected}

  defp update_failure(_), do: {:error, :plc_unavailable}

  defp latest_cid({:ok, %{status: 200, body: body} = response}) when is_binary(body) do
    with true <- Req.Response.get_header(response, "content-encoding") in [[], ["identity"]],
         {:ok, operation} <- Jason.decode(body),
         {:ok, cid} <- Operation.cid(operation) do
      {:ok, cid}
    else
      _ -> {:error, :invalid_plc_response}
    end
  end

  defp latest_cid({:ok, %{status: 200}}), do: {:error, :invalid_plc_response}
  defp latest_cid(_), do: {:error, :plc_unavailable}

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

  defp request(method, url, extra, opts, max_bytes \\ @max_response) do
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
      into: &collect(&1, &2, max_bytes)
    ]

    Req.request(request ++ extra ++ Keyword.take(opts, [:plug]))
  end

  defp collect({:data, data}, {request, response}, max_bytes) do
    if byte_size(response.body) + byte_size(data) > max_bytes,
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
