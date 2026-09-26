defmodule Atoll.Lexicon.ProcedureTest do
  use ExUnit.Case, async: true
  alias Atoll.Lexicon.Procedure
  @put "com.atproto.repo.putRecord"
  @body %{
    "repo" => "did:plc:test",
    "collection" => "com.example.record",
    "rkey" => "one",
    "record" => %{"$type" => "com.example.record"}
  }

  test "every routed POST method has a vendored schema" do
    methods = for %{verb: :post, path: "/xrpc/" <> nsid} <- AtollWeb.Router.__routes__(), do: nsid
    assert Enum.sort(methods) == Enum.sort(Procedure.methods())
  end

  test "required, nullable and optional fields have distinct semantics" do
    assert :ok = Procedure.validate(@put, @body)
    assert :ok = Procedure.validate(@put, Map.put(@body, "swapRecord", nil))
    assert {:error, _} = Procedure.validate(@put, Map.put(@body, "swapCommit", nil))
    assert {:error, _} = Procedure.validate(@put, Map.delete(@body, "record"))
    assert {:error, _} = Procedure.validate(@put, Map.put(@body, "record", nil))
    assert {:error, _} = Procedure.validate(@put, Map.put(@body, "rkey", ".."))
    assert {:error, _} = Procedure.validate(@put, Map.put(@body, "collection", "bad"))
  end

  test "JSON primitives are not coerced" do
    assert :ok = Procedure.validate(@put, Map.put(@body, "validate", false))
    assert {:error, _} = Procedure.validate(@put, Map.put(@body, "validate", "false"))

    for count <- ["1", 1.0, true, nil, 9_007_199_254_740_992] do
      assert {:error, _} =
               Procedure.validate("com.atproto.server.createInviteCode", %{"useCount" => count})
    end

    assert :ok = Procedure.validate("com.atproto.server.createInviteCodes", %{"useCount" => 1})
  end

  test "batch writes require a declared union tag and validate its fields" do
    nsid = "com.atproto.repo.applyWrites"
    create = %{"$type" => nsid <> "#create", "collection" => "com.example.record", "value" => %{}}
    input = %{"repo" => "did:plc:test", "writes" => [create]}
    assert :ok = Procedure.validate(nsid, input)

    for invalid <- [
          Map.delete(create, "$type"),
          Map.put(create, "$type", nsid <> "#future"),
          Map.put(create, "$type", "#create"),
          Map.delete(create, "value"),
          Map.put(create, "$type", nsid <> "#update")
        ] do
      assert {:error, _} = Procedure.validate(nsid, %{input | "writes" => [invalid]})
    end
  end

  test "root arrays and scalars are rejected, including Plug's wrapped representation" do
    for body <- [[], true, nil, "text", %{"_json" => []}] do
      assert {:error, _} = Procedure.validate("com.atproto.server.deactivateAccount", body)
    end
  end

  test "record contents remain the repository's responsibility" do
    assert :ok = Procedure.validate(@put, Map.put(@body, "record", %{"future" => [1, 2, 3]}))
    assert :ok = Procedure.validate(@put, Map.put(@body, "extension", "retained"))
    assert :ok = Procedure.validate("com.atproto.repo.uploadBlob", %{})
    assert :ok = Procedure.validate("com.atproto.repo.importRepo", %{})
  end

  test "datetime input follows strict ATProto syntax and calendar semantics" do
    for value <- [
          "1985-04-12T23:20:50.12345678912345Z",
          "0000-01-01T00:00:00Z",
          "1985-04-12T23:20:50+01:00"
        ] do
      assert :ok =
               Procedure.validate("com.atproto.server.deactivateAccount", %{
                 "deleteAfter" => value
               })
    end

    for value <- [
          "1985-04-12 23:20:50Z",
          "1985-04-12T23:20:50-00:00",
          "1985-02-30T23:20:50Z",
          "0000-01-01T00:00:00+01:00"
        ] do
      assert {:error, _} =
               Procedure.validate("com.atproto.server.deactivateAccount", %{
                 "deleteAfter" => value
               })
    end
  end
end
