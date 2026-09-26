defmodule Atoll.PLCAuditLogTest do
  use ExUnit.Case, async: true
  alias Atoll.Identity.PLC.AuditLog

  @valid ~w(log_bskyapp log_legacy_dholms log_tombstone log_nullification log_nullification_at_exactly_72h log_nullification_nontrivial log_nullified_tombstone log_duplicate_rotation_keys log_empty_rotation_keys log_bnewbold_robocracy)

  for name <- @valid do
    test "verifies upstream history #{name}" do
      entries = fixture(unquote(name))
      did = hd(entries)["did"]
      assert {:ok, result} = AuditLog.verify(did, entries)
      active = Enum.reject(entries, & &1["nullified"])
      assert result.active_cids == Enum.map(active, & &1["cid"])
      assert result.operation == List.last(active)["operation"]
      assert result.tombstoned == (result.operation["type"] == "plc_tombstone")

      assert result.nullified_cids ==
               entries |> Enum.filter(& &1["nullified"]) |> Enum.map(& &1["cid"])
    end
  end

  test "rejects every pinned invalid recovery, tombstone and signature history" do
    files = Path.wildcard(Path.join([__DIR__, "..", "fixtures", "plc", "log_invalid*.json"]))

    for file <- files do
      entries = file |> File.read!() |> Jason.decode!()
      assert {:error, :invalid_plc_log} = AuditLog.verify(hd(entries)["did"], entries), file
    end
  end

  test "rejects forged metadata, reordered or repeated operations and oversized logs" do
    entries = fixture("log_nullification")
    [first, second | rest] = entries
    did = first["did"]

    for bad <- [
          [],
          List.duplicate(first, 1001),
          [first, first],
          Enum.reverse(entries),
          [Map.put(first, "nullified", true), second | rest],
          [first, Map.put(second, "nullified", not second["nullified"]) | rest],
          [Map.put(first, "cid", second["cid"]), second | rest],
          [Map.put(first, "did", "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"), second | rest],
          [first, Map.put(second, "createdAt", "2000-01-01T00:00:00Z") | rest],
          [Map.put(first, "createdAt", "invalid"), second | rest]
        ] do
      assert {:error, :invalid_plc_log} = AuditLog.verify(did, bad)
    end

    assert {:error, :invalid_plc_log} =
             AuditLog.verify("did:plc:aaaaaaaaaaaaaaaaaaaaaaaa", entries)
  end

  test "offline operator command reports the verified head and rejects mismatched DIDs" do
    path = Path.join([__DIR__, "..", "fixtures", "plc", "log_nullification.json"])
    entries = fixture("log_nullification")
    did = hd(entries)["did"]
    output = ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Atoll.Plc.Verify.run([did, path]) end)
    result = Jason.decode!(output)
    assert result["did"] == did
    assert result["lastOperationCid"] == List.last(entries)["cid"]
    assert result["nullifiedOperations"] > 0

    assert_raise Mix.Error, fn ->
      Mix.Tasks.Atoll.Plc.Verify.run(["did:plc:aaaaaaaaaaaaaaaaaaaaaaaa", path])
    end

    assert_raise Mix.Error, fn -> Mix.Tasks.Atoll.Plc.Verify.run([]) end
  end

  test "offline operator command bounds file reads and never prints failed input" do
    path =
      Path.join(System.tmp_dir!(), "atoll-plc-log-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(path) end)
    File.write!(path, String.duplicate("x", 8 * 1024 * 1024 + 1))

    assert_raise Mix.Error,
                 "PLC audit verification failed: unreadable, oversized, malformed, or invalid log.",
                 fn ->
                   Mix.Tasks.Atoll.Plc.Verify.run(["did:plc:aaaaaaaaaaaaaaaaaaaaaaaa", path])
                 end
  end

  defp fixture(name),
    do:
      File.read!(Path.join([__DIR__, "..", "fixtures", "plc", name <> ".json"]))
      |> Jason.decode!()
end
