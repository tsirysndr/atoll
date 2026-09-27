defmodule Atoll.ProxyTargetTest do
  use ExUnit.Case, async: true
  alias Atoll.Proxy.Target

  @did "did:web:service.example.com"
  @aud @did <> "#atproto_labeler"

  defp document(services) do
    %{"id" => @did, "service" => services}
  end

  defp service(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "#atproto_labeler",
        "type" => "AtprotoLabeler",
        "serviceEndpoint" => "https://labels.example.com:8443/"
      },
      overrides
    )
  end

  test "requires one concrete DID and service fragment" do
    assert {:ok, {@did, "atproto_labeler"}} = Target.parse(@aud)

    for input <- [
          nil,
          [],
          @did,
          @did <> "#",
          @aud <> "#other",
          "x#s",
          @did <> "#a b",
          @did <> "#%xx",
          String.duplicate("a", 2049)
        ] do
      assert {:error, :invalid_proxy_target} = Target.parse(input)
    end
  end

  test "selects relative or absolute IDs without requiring an account key or PDS" do
    for id <- ["#atproto_labeler", @aud] do
      assert {:ok, uri} = Target.endpoint(document([service(%{"id" => id})]), @aud)
      assert uri.host == "labels.example.com"
      assert uri.port == 8443
    end
  end

  test "rejects wrong documents, missing or ambiguous services and malformed endpoint values" do
    for doc <- [
          nil,
          %{"id" => "did:web:other.example.com", "service" => [service()]},
          document([]),
          document(%{}),
          document([service(), service(%{"id" => @aud})]),
          document([service(%{"id" => "#other"})]),
          document([service(%{"type" => ""})]),
          document(List.duplicate(service(), 65))
        ] do
      assert {:error, :invalid_proxy_service} = Target.endpoint(doc, @aud)
    end

    for url <- [
          nil,
          [],
          %{"uri" => "https://example.com"},
          "http://example.com",
          "https://user:pass@example.com",
          "https://example.com/path",
          "https://example.com?query=1",
          "https://example.com#fragment",
          "https://example.com:0",
          "https://example.com:65536",
          "https://example.com/\n",
          "https://example.com\\evil"
        ] do
      assert {:error, :invalid_proxy_service} =
               Target.endpoint(document([service(%{"serviceEndpoint" => url})]), @aud)
    end
  end

  test "resolves through the DID method and independently checks the endpoint's public address" do
    resolver = [
      lookup: fn "service.example.com" -> {:ok, {8, 8, 8, 8}} end,
      request:
        Req.new(
          plug: fn conn ->
            assert conn.request_path == "/.well-known/did.json"
            Req.Test.json(conn, document([service()]))
          end
        )
    ]

    assert {:ok, target} =
             Target.resolve(@aud,
               resolver: resolver,
               lookup: fn "labels.example.com" -> {:ok, {1, 1, 1, 1}} end
             )

    assert target.audience == @aud
    assert target.address == {1, 1, 1, 1}

    for address <- [{127, 0, 0, 1}, {10, 0, 0, 1}, {169, 254, 169, 254}, {0, 0, 0, 0, 0, 0, 0, 1}] do
      assert {:error, :unsafe_proxy_destination} =
               Target.resolve(@aud, resolver: resolver, lookup: fn _ -> {:ok, address} end)
    end

    assert {:error, :dns_failed} =
             Target.resolve(@aud,
               resolver: resolver,
               lookup: fn _ -> {:error, :dns_failed} end
             )
  end
end
