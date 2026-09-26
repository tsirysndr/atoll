defmodule Atoll.PLCOperationTest do
  use ExUnit.Case, async: true
  alias Atoll.Identity.PLC.Operation
  alias Atoll.{CID, Multikey, SigningKey}

  test "matches upstream modern and legacy genesis DIDs, operation CIDs and signatures" do
    for file <- ["log_bskyapp.json", "log_legacy_dholms.json", "log_tombstone.json"] do
      [first | rest] = fixture(file)
      assert {:ok, did} = Operation.genesis_did(first["operation"])
      assert did == first["did"]
      assert :ok = Operation.verify_genesis(did, first["operation"])
      assert {:ok, cid} = Operation.cid(first["operation"])
      assert cid == first["cid"]
      # Only linear predecessor pairs are checked here, not log recovery/nullification.
      Enum.reduce(rest, first, fn entry, previous ->
        assert {:ok, cid} = Operation.cid(entry["operation"])
        assert cid == entry["cid"]

        if entry["operation"]["prev"] == previous["cid"] do
          assert {:ok, _} = Operation.verify_update(previous["operation"], entry["operation"])
        end

        entry
      end)
    end
  end

  test "rejects upstream noncanonical encodings, DER signatures, and both high-S curves" do
    for file <- ~w(log_invalid_sig_b64_newline.json log_invalid_sig_b64_padding_bits.json
                  log_invalid_sig_b64_padding_chars.json log_invalid_sig_der.json
                  log_invalid_sig_k256_high_s.json log_invalid_sig_p256_high_s.json) do
      [entry | _] = fixture(file)
      assert {:error, :invalid_plc_operation} = Operation.genesis_did(entry["operation"]), file
    end
  end

  test "constructs signed ATProto genesis operations with distinct rotation and repository keys" do
    for curve <- [:k256, :p256] do
      signer = SigningKey.generate(curve)
      repo_key = SigningKey.generate()
      {:ok, rotation} = Multikey.to_did_key(curve, signer.public)
      {:ok, signing} = Multikey.to_did_key(repo_key.curve, repo_key.public)

      assert {:ok, result} =
               Operation.create_atproto(
                 signing,
                 "alice.example.com",
                 "https://pds.example.com",
                 [rotation],
                 signer
               )

      assert result.did =~ ~r/\Adid:plc:[a-z2-7]{24}\z/
      assert result.operation["prev"] == nil
      assert result.operation["verificationMethods"] == %{"atproto" => signing}
      assert result.operation["alsoKnownAs"] == ["at://alice.example.com"]
      assert {:ok, ^rotation} = Operation.verify(result.operation, [rotation])
      assert {:error, :invalid_plc_operation} = Operation.verify(result.operation, [signing])
      assert :ok = Operation.verify_genesis(result.did, result.operation)

      assert {:error, :invalid_plc_operation} =
               Operation.verify_genesis("did:plc:aaaaaaaaaaaaaaaaaaaaaaaa", result.operation)

      assert {:ok, result.cid} == Operation.cid(result.operation)
    end
  end

  test "updates must chain the exact predecessor and use its keys; tombstones cannot be extended" do
    old_key = SigningKey.generate()
    new_key = SigningKey.generate()
    {:ok, old} = Multikey.to_did_key(:k256, old_key.public)
    {:ok, new} = Multikey.to_did_key(:k256, new_key.public)

    {:ok, first} =
      Operation.create_atproto(
        old,
        "alice.example.com",
        "https://pds.example.com",
        [old],
        old_key
      )

    unsigned =
      first.operation
      |> Map.delete("sig")
      |> Map.put("prev", first.cid)
      |> Map.put("rotationKeys", [new])

    {:ok, wrong} = Operation.sign(unsigned, new_key)
    assert {:error, :invalid_plc_operation} = Operation.verify_update(first.operation, wrong)
    {:ok, update} = Operation.sign(unsigned, old_key)
    assert {:ok, ^old} = Operation.verify_update(first.operation, update)
    {:ok, update_cid} = Operation.cid(update)
    {:ok, tombstone} = Operation.sign(%{"type" => "plc_tombstone", "prev" => update_cid}, new_key)
    assert {:ok, ^new} = Operation.verify_update(update, tombstone)
    assert {:error, :invalid_plc_operation} = Operation.verify_update(first.operation, tombstone)
    assert {:error, :invalid_plc_operation} = Operation.genesis_did(tombstone)
    assert {:error, :invalid_plc_operation} = Operation.verify_update(tombstone, update)
  end

  test "rejects malformed structures, oversized operations, invalid predecessors and duplicate keys" do
    signer = SigningKey.generate()
    {:ok, key} = Multikey.to_did_key(:k256, signer.public)

    {:ok, first} =
      Operation.create_atproto(key, "alice.example.com", "https://pds.example.com", [key], signer)

    unsigned = Map.delete(first.operation, "sig")

    for bad <- [
          Map.delete(unsigned, "prev"),
          Map.put(unsigned, "extra", true),
          Map.put(unsigned, "rotationKeys", []),
          Map.put(unsigned, "rotationKeys", [key, key]),
          Map.put(unsigned, "rotationKeys", ["did:key:bad"]),
          Map.put(unsigned, "prev", CID.to_base32(CID.create("raw", :raw))),
          Map.put(unsigned, "alsoKnownAs", [String.duplicate("x", 7500)]),
          Map.put(unsigned, "verificationMethods", %{"atproto" => "not-a-key"}),
          Map.put(unsigned, "services", %{"test" => %{"type" => "test", "endpoint" => 3}})
        ] do
      assert {:error, :invalid_plc_operation} = Operation.sign(bad, signer)
    end

    for handle <- [nil, "", "Alice.example.com", "localhost"] do
      assert {:error, :invalid_plc_operation} =
               Operation.create_atproto(key, handle, "https://pds.example.com", [key], signer)
    end

    assert {:error, :invalid_plc_operation} =
             Operation.create_atproto(
               key,
               "alice.example.com",
               "http://pds.example.com",
               [key],
               signer
             )

    assert {:error, :invalid_plc_operation} = Operation.sign(first.operation, signer)

    assert {:error, :invalid_plc_operation} =
             Operation.verify(
               Map.put(first.operation, "alsoKnownAs", ["at://changed.example.com"]),
               [key]
             )
  end

  defp fixture(file),
    do: File.read!(Path.join([__DIR__, "..", "fixtures", "plc", file])) |> Jason.decode!()
end
