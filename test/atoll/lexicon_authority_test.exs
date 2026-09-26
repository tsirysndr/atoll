defmodule Atoll.LexiconAuthorityTest do
  use ExUnit.Case, async: true
  alias Atoll.Lexicon.Authority
  @did "did:plc:ewvi7nxzyoun6zhxrhs64oiz"

  test "uses the exact authority group and preserves the schema name's case" do
    lookup = fn name ->
      assert name == "_lexicon.blogging.lab.dept.university.edu"

      [
        [~c"unrelated"],
        ["did=not-a-did"],
        ["did=did:plc:", ~c"ewvi7nxzyoun6zhxrhs64oiz"],
        ["did=" <> @did]
      ]
    end

    assert {:ok, result} =
             Authority.discover("EDU.University.Dept.Lab.Blogging.getBlogPost",
               txt_lookup: lookup
             )

    assert result.nsid == "edu.university.dept.lab.blogging.getBlogPost"
    assert result.did == @did

    assert result.uri ==
             "at://" <>
               @did <> "/com.atproto.lexicon.schema/edu.university.dept.lab.blogging.getBlogPost"
  end

  test "missing or conflicting claims never search a parent namespace" do
    for {records, error} <- [
          {[], :lexicon_authority_not_found},
          {[["did=" <> @did], ["did=did:web:other.example.com"]], :ambiguous_lexicon_authority}
        ] do
      assert {:error, ^error} =
               Authority.discover("com.example.group.record",
                 txt_lookup: fn name ->
                   assert name == "_lexicon.group.example.com"
                   send(self(), :lookup)
                   records
                 end
               )

      assert_receive :lookup
      refute_receive :lookup
    end
  end

  test "invalid identifiers, reserved domains and unrepresentable DNS names fail before lookup" do
    lookup = fn _ -> flunk("must not resolve invalid namespace") end

    for nsid <- [
          nil,
          "com.example",
          "com.example.*",
          "com.example.record#main",
          "com.example.1record"
        ] do
      assert {:error, :invalid_nsid} = Authority.discover(nsid, txt_lookup: lookup)
    end

    for nsid <- [
          "local.example.record",
          Enum.join(
            [
              String.duplicate("a", 63),
              String.duplicate("b", 63),
              String.duplicate("c", 63),
              String.duplicate("d", 60),
              "record"
            ],
            "."
          )
        ] do
      assert {:error, :invalid_lexicon_authority} = Authority.discover(nsid, txt_lookup: lookup)
    end
  end

  test "TXT records, chunks and aggregate bytes are bounded; resolver failure stays an error" do
    for records <- [
          :timeout,
          List.duplicate(["did=" <> @did], 33),
          [[String.duplicate("x", 256)]],
          [List.duplicate("x", 17)],
          List.duplicate(List.duplicate(String.duplicate("x", 255), 8), 9),
          [[[:bad]]]
        ] do
      assert {:error, :lexicon_authority_unavailable} =
               Authority.discover("com.example.record", txt_lookup: fn _ -> records end)
    end

    assert {:error, :lexicon_authority_unavailable} =
             Authority.discover("com.example.record", txt_lookup: fn _ -> exit(:timeout) end)
  end

  test "delegation resolves the DID key and PDS without requiring a matching account handle" do
    key = Atoll.SigningKey.generate()
    {:ok, multikey} = Atoll.Multikey.encode(key.curve, key.public)

    doc = %{
      "id" => @did,
      "alsoKnownAs" => ["at://unrelated.example.com"],
      "verificationMethod" => [
        %{
          "id" => "#atproto",
          "controller" => @did,
          "type" => "Multikey",
          "publicKeyMultibase" => multikey
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

    assert {:ok, result} =
             Authority.resolve("com.example.record",
               txt_lookup: fn name ->
                 assert name == "_lexicon.example.com"
                 [["did=" <> @did]]
               end,
               lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
               request: Req.new(plug: fn conn -> Req.Test.json(conn, doc) end)
             )

    assert result.identity.signing_key == %{curve: key.curve, public: key.public}
    assert result.identity.pds == "https://pds.example.com"
    assert result.nsid == "com.example.record"
  end
end
