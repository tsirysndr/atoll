defmodule Atoll.LexiconFetcherTest do
  use ExUnit.Case, async: true
  alias Atoll.Lexicon.Fetcher
  @did "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
  @nsid "com.example.record"
  @uri "at://#{@did}/com.atproto.lexicon.schema/#{@nsid}"

  defp record do
    value = %{
      "$type" => "com.atproto.lexicon.schema",
      "lexicon" => 1,
      "id" => @nsid,
      "defs" => %{
        "main" => %{
          "type" => "record",
          "key" => "tid",
          "record" => %{"type" => "object", "properties" => %{}}
        }
      }
    }

    cid = value |> Atoll.CBOR.encode!() |> Atoll.CID.create(:dag_cbor) |> Atoll.CID.to_base32()
    %{"uri" => @uri, "cid" => cid, "value" => value}
  end

  defp options(handler, pds \\ "https://pds.example.com:8443", proof_handler \\ nil) do
    key = Atoll.SigningKey.generate()
    {:ok, multikey} = Atoll.Multikey.encode(key.curve, key.public)

    doc = %{
      "id" => @did,
      "verificationMethod" => [
        %{
          "id" => "#atproto",
          "controller" => @did,
          "type" => "Multikey",
          "publicKeyMultibase" => multikey
        }
      ],
      "service" => [
        %{"id" => "#atproto_pds", "type" => "AtprotoPersonalDataServer", "serviceEndpoint" => pds}
      ]
    }

    [
      txt_lookup: fn "_lexicon.example.com" -> [["did=" <> @did]] end,
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
      request:
        Req.new(
          plug: fn conn ->
            case conn.request_path do
              "/" <> @did ->
                Req.Test.json(conn, doc)

              "/xrpc/com.atproto.repo.getRecord" ->
                handler.(conn)

              "/xrpc/com.atproto.sync.getRecord" ->
                if proof_handler do
                  proof_handler.(conn, key)
                else
                  assert URI.decode_query(conn.query_string) == %{
                           "did" => @did,
                           "collection" => "com.atproto.lexicon.schema",
                           "rkey" => @nsid
                         }

                  assert Plug.Conn.get_req_header(conn, "accept") == ["application/vnd.ipld.car"]
                  Plug.Conn.send_resp(conn, 200, proof(key))
                end
            end
          end
        )
    ]
  end

  defp proof(key, document \\ record()["value"]) do
    bytes = Atoll.CBOR.encode!(document)
    cid = Atoll.CID.create(bytes, :dag_cbor)
    {:ok, tree} = Atoll.MST.new(%{("com.atproto.lexicon.schema/" <> @nsid) => cid})
    {:ok, rev} = Atoll.TID.next()
    {:ok, commit} = Atoll.Commit.create(@did, tree.root, rev, key)
    blocks = tree.blocks |> Map.put(cid, bytes) |> Map.put(commit.cid, commit.bytes)
    {:ok, archive} = Atoll.CAR.encode([commit.cid], blocks)
    archive
  end

  test "fetches only the delegated PDS and checks URI, schema identity and content CID" do
    opts =
      options(fn conn ->
        assert conn.host == "8.8.8.8"
        assert Plug.Conn.get_req_header(conn, "host") == ["pds.example.com:8443"]
        assert Plug.Conn.get_req_header(conn, "authorization") == []

        assert URI.decode_query(conn.query_string) == %{
                 "repo" => @did,
                 "collection" => "com.atproto.lexicon.schema",
                 "rkey" => @nsid
               }

        Req.Test.json(conn, record())
      end)

    assert {:ok, result} = Fetcher.fetch(@nsid, opts)
    assert result.document == record()["value"]
    assert result.cid == record()["cid"]
    assert result.did == @did
    assert {:ok, _} = Atoll.CID.from_base32(result.commit)
    assert Atoll.TID.valid?(result.rev)
  end

  test "rejects substituted records, malformed schemas and mismatched content" do
    original = record()

    for response <- [
          Map.put(
            original,
            "uri",
            "at://did:web:other.example.com/com.atproto.lexicon.schema/#{@nsid}"
          ),
          put_in(original, ["value", "id"], "com.example.other"),
          put_in(original, ["value", "$type"], "com.example.other"),
          put_in(original, ["value", "lexicon"], 2),
          put_in(original, ["value", "defs"], %{}),
          put_in(original, ["value", "description"], "tampered"),
          Map.put(original, "cid", "bad"),
          %{},
          []
        ] do
      assert {:error, :invalid_lexicon_record} =
               Fetcher.fetch(@nsid, options(&Req.Test.json(&1, response)))
    end
  end

  test "bounds bodies and refuses duplicate JSON keys, redirects and compressed responses" do
    for {body, error} <- [
          {String.duplicate("x", 262_145), :lexicon_too_large},
          {"{\"value\":{},\"value\":{}}", :invalid_lexicon_record},
          {String.duplicate("[", 66) <> "0" <> String.duplicate("]", 66), :invalid_lexicon_record}
        ] do
      assert {:error, ^error} = Fetcher.fetch(@nsid, options(&Plug.Conn.send_resp(&1, 200, body)))
    end

    assert {:error, :resolution_failed} =
             Fetcher.fetch(
               @nsid,
               options(fn conn ->
                 conn
                 |> Plug.Conn.put_resp_header("location", "https://other.example.com")
                 |> Plug.Conn.send_resp(302, "")
               end)
             )

    assert {:error, :resolution_failed} =
             Fetcher.fetch(
               @nsid,
               options(fn conn ->
                 conn
                 |> Plug.Conn.put_resp_header("content-encoding", "gzip")
                 |> Plug.Conn.send_resp(200, Jason.encode!(record()))
               end)
             )

    assert {:error, :lexicon_not_found} =
             Fetcher.fetch(@nsid, options(&Plug.Conn.send_resp(&1, 404, "")))
  end

  test "requires a matching proof signed by the resolved account key" do
    for handler <- [
          fn conn, _ -> Plug.Conn.send_resp(conn, 200, proof(Atoll.SigningKey.generate())) end,
          fn conn, key ->
            Plug.Conn.send_resp(
              conn,
              200,
              proof(key, Map.put(record()["value"], "description", "different"))
            )
          end,
          fn conn, _ -> Plug.Conn.send_resp(conn, 200, "not a CAR") end
        ] do
      assert {:error, :invalid_record_proof} =
               Fetcher.fetch(
                 @nsid,
                 options(&Req.Test.json(&1, record()), "https://pds.example.com", handler)
               )
    end
  end

  test "proof fetch bounds bytes and cannot fall back to unsigned JSON" do
    for {status, bytes, reason} <- [
          {404, "", :lexicon_not_found},
          {503, "", :resolution_failed},
          {200, String.duplicate("x", 2_097_153), :lexicon_too_large}
        ] do
      handler = fn conn, _ -> Plug.Conn.send_resp(conn, status, bytes) end

      assert {:error, ^reason} =
               Fetcher.fetch(
                 @nsid,
                 options(&Req.Test.json(&1, record()), "https://pds.example.com", handler)
               )
    end
  end

  test "rejects private PDS destinations before contacting them" do
    opts = options(fn _ -> flunk("must not contact private PDS") end)

    opts =
      Keyword.put(opts, :lookup, fn
        "plc.directory" -> {:ok, {8, 8, 8, 8}}
        "pds.example.com" -> {:ok, {127, 0, 0, 1}}
      end)

    assert {:error, :unsafe_destination} = Fetcher.fetch(@nsid, opts)
  end
end
