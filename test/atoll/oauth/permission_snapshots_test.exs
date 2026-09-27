defmodule Atoll.OAuth.PermissionSnapshotsTest do
  use ExUnit.Case, async: true
  alias Atoll.OAuth.{ClientMetadata, PermissionSnapshots}

  test "include grant narrowing may drop an audience but cannot replace it or cross namespaces" do
    original = %{"scope" => "atproto include:com.example.auth?aud=did:web:api.example.com%23app"}

    assert ClientMetadata.scopes_allowed?(
             original,
             "atproto include?nsid=com.example.auth&aud=did:web:api.example.com%23app"
           )

    assert ClientMetadata.scopes_allowed?(original, "atproto include:com.example.auth")

    refute ClientMetadata.scopes_allowed?(
             original,
             "atproto include:com.example.auth?aud=did:web:other.example.com%23app"
           )

    refute ClientMetadata.scopes_allowed?(
             %{"scope" => "atproto include:com.example.auth"},
             original["scope"]
           )

    refute ClientMetadata.scopes_allowed?(original, "atproto include:com.other.auth")
  end

  test "snapshot limits reject oversized catalogs and excessive invocations before resolution" do
    includes = for n <- 1..17, do: "include:com.example.set#{n}"

    assert {:error, :invalid_scope} =
             PermissionSnapshots.resolve(Enum.join(["atproto" | includes], " "), %{},
               permission_set_options: [
                 fetch: fn _, _ -> flunk("too many includes must not resolve") end
               ]
             )

    sets =
      Map.new(1..5, fn n ->
        nsid = "com.example.set#{n}"

        {nsid,
         %{
           "provenance" => %{},
           "fetched_at" => 1,
           "document" => %{
             "$type" => "com.atproto.lexicon.schema",
             "lexicon" => 1,
             "id" => nsid,
             "defs" => %{
               "main" => %{
                 "type" => "permission-set",
                 "permissions" => [
                   %{
                     "type" => "permission",
                     "resource" => "future",
                     "data" => String.duplicate("x", 230_000)
                   }
                 ]
               }
             }
           }
         }}
      end)

    scope = Enum.join(["atproto" | Enum.take(includes, 5)], " ")
    assert {:error, :invalid_scope} = PermissionSnapshots.select(scope, sets)

    assert {:error, :invalid_scope} =
             PermissionSnapshots.effective("atproto include:com.example.absent", sets)

    assert {:ok, %{}} = PermissionSnapshots.select("atproto", sets)
  end
end
