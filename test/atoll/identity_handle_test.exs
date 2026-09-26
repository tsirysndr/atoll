defmodule Atoll.IdentityHandleTest do
  use ExUnit.Case, async: true
  alias Atoll.Identity.Handle
  alias Atoll.{Multikey, SigningKey}
  @handle "alice.example.com"
  @did "did:plc:ewvi7nxzyoun6zhxrhs64oiz"

  test "normalizes handles and joins TXT chunks, ignoring unrelated and invalid records" do
    txt = fn name ->
      assert name == "_atproto." <> @handle

      [
        [~c"unrelated"],
        [~c"did=not-a-did"],
        ["did=did:plc:", "ewvi7nxzyoun6zhxrhs64oiz"],
        ["did=" <> @did]
      ]
    end

    assert Handle.resolve("Alice.Example.Com", txt_lookup: txt) == {:ok, @did}
  end

  test "conflicting DNS claims fail without HTTPS fallback" do
    txt = fn _ -> [["did=" <> @did], ["did=did:web:other.example.com"]] end

    assert Handle.resolve(@handle,
             txt_lookup: txt,
             lookup: fn _ -> flunk("HTTPS must not run") end
           ) == {:error, :ambiguous_handle}
  end

  test "HTTPS fallback strips surrounding whitespace and accepts successful responses" do
    request =
      Req.new(
        plug: fn conn ->
          assert conn.request_path == "/.well-known/atproto-did"
          assert Plug.Conn.get_req_header(conn, "host") == [@handle]
          Plug.Conn.send_resp(conn, 201, " \n" <> @did <> "\n")
        end
      )

    assert Handle.resolve(@handle, options(request)) == {:ok, @did}
  end

  test "HTTPS rejects redirects, invalid bodies, oversized bodies and private destinations" do
    for {status, body} <- [
          {302, @did},
          {404, ""},
          {200, "did=" <> @did},
          {200, <<255>>},
          {200, String.duplicate(" ", 4097)}
        ] do
      request = Req.new(plug: fn conn -> Plug.Conn.send_resp(conn, status, body) end)
      assert Handle.resolve(@handle, options(request)) == {:error, :handle_not_found}
    end

    assert Handle.resolve(@handle,
             txt_lookup: fn _ -> [] end,
             lookup: fn _ -> {:ok, {127, 0, 0, 1}} end
           ) == {:error, :handle_not_found}
  end

  test "rejects reserved names before DNS or HTTP and bypasses overlong DNS names" do
    for name <- [
          nil,
          "@alice.example.com",
          "alice.local",
          "handle.invalid",
          "alice.test",
          "127.0.0.1"
        ] do
      assert Handle.resolve(name, txt_lookup: fn _ -> flunk("must not query DNS") end) ==
               {:error, :invalid_handle}
    end

    long =
      Enum.join(
        [
          String.duplicate("a", 63),
          String.duplicate("b", 63),
          String.duplicate("c", 63),
          String.duplicate("d", 54),
          "com"
        ],
        "."
      )

    assert byte_size(long) > 244
    request = Req.new(plug: fn conn -> Plug.Conn.send_resp(conn, 200, @did) end)
    opts = options(request) |> Keyword.put(:txt_lookup, fn _ -> flunk("DNS name too long") end)
    assert Handle.resolve(long, opts) == {:ok, @did}
  end

  test "requires the resolved DID document's first claimed handle to match" do
    key = SigningKey.generate()
    {:ok, encoded} = Multikey.encode(key.curve, key.public)

    for {claims, result} <- [
          {["at://" <> @handle], :ok},
          {["at://other.example.com", "at://" <> @handle], :mismatch},
          {[], :mismatch}
        ] do
      document = %{
        "id" => @did,
        "alsoKnownAs" => claims,
        "verificationMethod" => [
          %{
            "id" => "#atproto",
            "controller" => @did,
            "type" => "Multikey",
            "publicKeyMultibase" => encoded
          }
        ],
        "service" => [
          %{
            "id" => "#atproto_pds",
            "type" => "AtprotoPersonalDataServer",
            "serviceEndpoint" => "https://pds.example.com"
          }
        ]
      }

      request = Req.new(plug: fn conn -> Req.Test.json(conn, document) end)
      opts = options(request) |> Keyword.put(:txt_lookup, fn _ -> [["did=" <> @did]] end)

      if result == :ok do
        assert {:ok, %{handle: @handle, did: @did}} = Handle.verify(@handle, opts)
      else
        assert Handle.verify(@handle, opts) == {:error, :handle_mismatch}
      end
    end
  end

  defp options(request),
    do: [request: request, txt_lookup: fn _ -> [] end, lookup: fn _ -> {:ok, {8, 8, 8, 8}} end]
end
