defmodule Atoll.OAuth.PermissionsTest do
  use ExUnit.Case, async: true
  alias Atoll.OAuth.{Permissions, ClientMetadata}

  test "repository scopes support positional and repeated query collections and actions" do
    for scope <- [
          "repo:com.example.post",
          "repo:com%2Eexample.post?",
          "repo?collection=com.example.post"
        ] do
      assert {:ok, %{collections: ["com.example.post"], actions: actions}} =
               Permissions.repo(scope)

      assert Enum.sort(actions) == ~w(create delete update)
    end

    assert {:ok,
            %{
              collections: ["com.example.post", "com.example.profile"],
              actions: ["create", "delete"]
            }} =
             Permissions.repo(
               "repo?collection=com.example.post&collection=com.example.profile&action=create&action=delete"
             )

    assert Permissions.allows_repo?("atproto repo:*?action=delete", "com.example.post", "delete")
    refute Permissions.allows_repo?("atproto repo:*?action=delete", "com.example.post", "create")
    refute Permissions.write_admission?("atproto repo:*", :upload_blob)
  end

  test "invalid repository permissions cannot authorize or enter PAR" do
    for scope <- [
          nil,
          "repo",
          "repo:",
          "repo:*?collection=com.example.post",
          "repo:com.example.*",
          "repo:*?action=read",
          "repo:*?action=",
          "repo:*?action=create&action=create",
          "repo:*?unknown=yes",
          "repo:*?action=create&",
          "repo:*?action",
          "repo:%FF",
          "repo:%",
          "repo:*?action=%63reate&%61ction=create",
          "repo:*?action=create?x=y",
          "repo:com.example.é",
          "repo?collection=com.example.post%00",
          "repo:* action=delete",
          "repo:*?action=create+update",
          "repo:" <> String.duplicate("a", 4096),
          "repo?" <> Enum.join(List.duplicate("collection=com.example.post", 129), "&")
        ] do
      assert {:error, :invalid_scope} = Permissions.repo(scope)
      refute Permissions.supported?(scope)
    end

    for scope <- ~w(blob:*/* rpc:* identity:* account:email include:com.example.permissions),
        do: refute(Permissions.supported?(scope))
  end

  test "narrowing combines grants but cannot widen collections or actions" do
    declared = %{"scope" => "atproto repo:*?action=create repo:com.example.post?action=update"}

    assert ClientMetadata.scopes_allowed?(
             declared,
             "atproto repo:com.example.post?action=create&action=update"
           )

    assert ClientMetadata.scopes_allowed?(declared, "atproto repo:com.other.post?action=create")
    refute ClientMetadata.scopes_allowed?(declared, "atproto repo:com.other.post?action=update")
    refute ClientMetadata.scopes_allowed?(declared, "atproto repo:*?action=update")
    refute ClientMetadata.scopes_allowed?(declared, "atproto repo:com.example.post")
    refute ClientMetadata.scopes_allowed?(declared, "atproto transition:generic")

    assert ClientMetadata.scopes_allowed?(
             %{"scope" => "atproto repo:*"},
             "atproto repo:com.example.post"
           )

    refute ClientMetadata.scopes_allowed?(
             %{"scope" => "atproto repo:com.example.post"},
             "atproto repo:*"
           )
  end
end
