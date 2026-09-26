defmodule Atoll.PLCVerifiedResolutionTest do
  use ExUnit.Case, async: false
  alias Atoll.Identity.{Resolver, Cache, Document}
  alias Atoll.Identity.PLC.AuditLog

  setup do
    previous = Application.fetch_env(:atoll, :plc_resolution_mode)
    Application.put_env(:atoll, :plc_resolution_mode, :audit)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:atoll, :plc_resolution_mode, value)
        :error -> Application.delete_env(:atoll, :plc_resolution_mode)
      end
    end)

    :ok
  end

  test "configured audit resolution derives current identity from signed operations only" do
    entries = fixture("log_bskyapp")
    did = hd(entries)["did"]
    last = List.last(entries)["operation"]

    request =
      Req.new(
        plug: fn conn ->
          assert conn.host == "8.8.8.8"
          assert Plug.Conn.get_req_header(conn, "host") == ["plc.directory"]
          assert conn.request_path == "/#{did}/log/audit"
          Req.Test.json(conn, entries)
        end
      )

    assert {:ok, identity} = Resolver.resolve(did, request: request, lookup: &lookup/1)
    assert identity.document["alsoKnownAs"] == last["alsoKnownAs"]
    assert identity.pds == last["services"]["atproto_pds"]["endpoint"]
    assert {:ok, key} = Atoll.Multikey.from_did_key(last["verificationMethods"]["atproto"])
    assert identity.signing_key == key
    assert identity.document["verificationMethod"] |> Enum.any?(&(&1["id"] == did <> "#atproto"))
  end

  test "verified caches cannot reuse directory documents and forced failures evict verified entries" do
    entries = fixture("log_bskyapp")
    did = hd(entries)["did"]
    cache = start_supervised!({Cache, []})
    trusted = %{"id" => did, "unverified" => true}
    assert {:ok, ^trusted} = Cache.fetch(cache, did, false, fn -> {:ok, trusted} end)
    opts = [cache: cache, lookup: &lookup/1, request: request(entries)]
    assert {:ok, doc} = Resolver.resolve_document(did, opts)
    refute Map.has_key?(doc, "unverified")

    cached_opts =
      Keyword.put(opts, :request, Req.new(plug: fn _ -> flunk("expected verified cache") end))

    assert {:ok, ^doc} = Resolver.resolve_document(did, cached_opts)

    assert {:ok, ^trusted} =
             Resolver.resolve_document(
               did,
               Keyword.put(cached_opts, :plc_resolution_mode, :directory)
             )

    bad = List.update_at(entries, 0, &Map.put(&1, "nullified", true))
    forced = opts |> Keyword.put(:force_refresh, true) |> Keyword.put(:request, request(bad))
    assert {:error, :invalid_did_document} = Resolver.resolve_document(did, forced)
    # Re-fetch is required after invalidation; the directory-mode entry is independent.
    assert {:ok, ^doc} = Resolver.resolve_document(did, opts)
  end

  test "tombstones and forged logs fail without falling back to rendered documents" do
    for {name, expected} <- [
          {"log_tombstone", :did_not_found},
          {"log_invalid_nullification_too_slow", :invalid_did_document}
        ] do
      entries = fixture(name)
      did = hd(entries)["did"]

      req =
        Req.new(
          plug: fn conn ->
            assert String.ends_with?(conn.request_path, "/log/audit")
            Req.Test.json(conn, entries)
          end
        )

      assert {:error, ^expected} = Resolver.resolve_document(did, lookup: &lookup/1, request: req)
    end
  end

  test "audit fetching preserves address, redirect and response-size limits" do
    entries = fixture("log_bskyapp")
    did = hd(entries)["did"]

    assert {:error, :unsafe_destination} =
             Resolver.resolve_document(did,
               lookup: fn _ -> {:ok, {127, 0, 0, 1}} end,
               request: Req.new(plug: fn _ -> flunk("private destination") end)
             )

    for {status, body, error} <- [
          {302, "", :resolution_failed},
          {200, "not json", :invalid_did_document},
          {200, String.duplicate("x", 8 * 1024 * 1024 + 1), :did_document_too_large}
        ] do
      req =
        Req.new(
          plug: fn conn ->
            conn
            |> Plug.Conn.put_resp_header("location", "https://other.example.com")
            |> Plug.Conn.send_resp(status, body)
          end
        )

      assert {:error, ^error} = Resolver.resolve_document(did, lookup: &lookup/1, request: req)
    end
  end

  test "legacy genesis documents preserve normalized aliases, service and signing key" do
    [first | _] = fixture("log_legacy_dholms")
    did = first["did"]
    assert {:ok, doc} = AuditLog.document(did, [first])
    assert doc["alsoKnownAs"] == ["at://" <> first["operation"]["handle"]]
    assert {:ok, identity} = Document.parse(doc, did)
    assert identity.pds == first["operation"]["service"]
    assert doc["@context"] |> Enum.member?("https://w3id.org/security/suites/secp256k1-2019/v1")
  end

  test "only the two explicit resolution policies are configured" do
    assert Resolver.plc_mode_from_env!(nil) == :directory
    assert Resolver.plc_mode_from_env!("directory") == :directory
    assert Resolver.plc_mode_from_env!("audit") == :audit

    for value <- ["", "true", "AUDIT", "fallback"],
        do: assert_raise(ArgumentError, fn -> Resolver.plc_mode_from_env!(value) end)
  end

  defp lookup("plc.directory"), do: {:ok, {8, 8, 8, 8}}
  defp request(entries), do: Req.new(plug: fn conn -> Req.Test.json(conn, entries) end)

  defp fixture(name),
    do:
      File.read!(Path.join([__DIR__, "..", "fixtures", "plc", name <> ".json"]))
      |> Jason.decode!()
end
