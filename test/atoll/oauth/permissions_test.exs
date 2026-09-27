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

    for scope <- ~w(rpc:* identity:* include:com.example.permissions),
        do: refute(Permissions.supported?(scope))
  end

  test "account scopes have scalar attributes and read defaults" do
    for scope <- ["account:email", "account?attr=email", "account:email?action=read"] do
      assert {:ok, %{attr: "email", action: "read"}} = Permissions.account(scope)
      assert Permissions.supported?(scope)
    end

    assert {:ok, %{attr: "repo", action: "manage"}} =
             Permissions.account("account?action=manage&attr=repo")

    for scope <- [
          "account",
          "account:*",
          "account:status",
          "account:email?action=write",
          "account:email?attr=email",
          "account?attr=email&attr=repo",
          "account:email?action=read&action=manage",
          "account:email?unknown=yes"
        ] do
      assert {:error, :invalid_scope} = Permissions.account(scope)
      refute Permissions.supported?(scope)
    end
  end

  test "account manage can narrow to read but cannot cross attributes or grant record writes" do
    grants = %{"scope" => "atproto account:email?action=manage account:repo?action=manage"}
    assert ClientMetadata.scopes_allowed?(grants, "atproto account:email account:repo")

    refute ClientMetadata.scopes_allowed?(
             %{"scope" => "atproto account:email"},
             "atproto account:email?action=manage"
           )

    refute ClientMetadata.scopes_allowed?(
             %{"scope" => "atproto account:email?action=manage"},
             "atproto account:repo?action=manage"
           )

    assert Permissions.write_admission?(grants["scope"], :import_repo)

    for action <- [
          :request_email_confirmation,
          :confirm_email,
          :request_email_update,
          :update_email
        ] do
      assert Permissions.write_admission?(grants["scope"], action)

      for scope <- [
            "atproto",
            "atproto transition:generic transition:email",
            "atproto repo:*",
            "atproto account:email"
          ] do
        refute Permissions.write_admission?(scope, action)
        refute Permissions.write_admission?(scope, :import_repo)
      end
    end

    refute Permissions.write_admission?("atproto account:repo", :import_repo)

    for action <- [:create, :put, :delete, :batch, :upload_blob],
        do: refute(Permissions.write_admission?(grants["scope"], action))

    assert Permissions.allows_account?("atproto transition:email", "email", "read")
    refute Permissions.allows_account?("atproto transition:email", "email", "manage")
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

  test "blob permissions support MIME patterns, repeated accept parameters and normalization" do
    assert {:ok, %{accept: ["image/*"]}} = Permissions.blob("blob:IMAGE/*")

    assert {:ok, %{accept: ["image/png", "text/plain"]}} =
             Permissions.blob("blob?accept=image%2Fpng&accept=text/plain")

    assert {:ok, %{accept: ["application/ld+json"]}} =
             Permissions.blob("blob:application/ld+json?")

    assert {:ok, %{accept: ["application/ld+json"]}} =
             Permissions.blob("blob?accept=application/ld%2Bjson")

    assert Permissions.supported?("blob:*/*")
    assert Permissions.write_admission?("atproto blob:image/*", :upload_blob)
    refute Permissions.write_admission?("atproto blob:*/*", :put)
    assert Permissions.allows_blob?("atproto blob:image/*", "IMAGE/PNG")
    refute Permissions.allows_blob?("atproto blob:image/*", "text/plain")
    refute Permissions.allows_blob?("atproto blob:*/*", "text/plain; charset=utf-8")
  end

  test "blob scope attenuation cannot expand wildcard coverage" do
    grants = %{"scope" => "atproto blob:image/* blob:text/plain"}

    assert ClientMetadata.scopes_allowed?(
             grants,
             "atproto blob?accept=image/png&accept=text/plain"
           )

    refute ClientMetadata.scopes_allowed?(grants, "atproto blob:*/*")
    refute ClientMetadata.scopes_allowed?(grants, "atproto blob:text/*")
    refute ClientMetadata.scopes_allowed?(grants, "atproto blob:image/*?accept=text/plain")

    refute ClientMetadata.scopes_allowed?(
             %{"scope" => "atproto blob:image/png blob:image/jpeg"},
             "atproto blob:image/*"
           )

    assert ClientMetadata.scopes_allowed?(
             %{"scope" => "atproto blob:*/*"},
             "atproto blob:image/*"
           )

    refute ClientMetadata.scopes_allowed?(%{"scope" => "atproto repo:*"}, "atproto blob:*/*")
  end

  test "malformed MIME permission patterns are rejected without broadening access" do
    for scope <- [
          "blob",
          "blob:",
          "blob:*",
          "blob:*/png",
          "blob:image/p*",
          "blob:image/**",
          "blob:application/*+json",
          "blob:image/png;foo=bar",
          "blob:image/png?accept=image/jpeg",
          "blob?accept=",
          "blob?accept=image/png&action=upload",
          "blob:%ff",
          "blob:%",
          "blob?accept=application/ld+json",
          "blob?accept=image/png%00",
          "blob:image/png&accept=text/plain"
        ] do
      assert {:error, :invalid_scope} = Permissions.blob(scope)
      refute Permissions.supported?(scope)
      refute Permissions.allows_blob?("atproto " <> scope, "image/png")
    end
  end

  test "RPC scope syntax constrains audience or methods, with one scalar audience" do
    assert {:ok, %{audience: "*", methods: ["app.example.getFeed"]}} =
             Permissions.rpc("rpc:app.example.getFeed?aud=*")

    assert {:ok, %{audience: "did:web:api.example.com#appview", methods: ["*"]}} =
             Permissions.rpc("rpc?lxm=*&aud=did:web:api.example.com%23appview")

    assert {:ok, %{methods: ["app.example.getFeed", "app.example.getProfile"]}} =
             Permissions.rpc("rpc?lxm=app.example.getFeed&lxm=app.example.getProfile&aud=*")

    for scope <- [
          "rpc:*?aud=*",
          "rpc?lxm=app.example.getFeed&lxm=*&aud=*",
          "rpc:app.example.getFeed",
          "rpc:*?aud=did:web:api.example.com",
          "rpc:*?aud=did:web:api.example.com%23",
          "rpc:*?aud=did:web:api.example.com%23a%23b",
          "rpc:*?aud=not-a-did%23service",
          "rpc:*?aud=did:web:%25bad%23service%25",
          "rpc:*?aud=did:web:api.example.com%23svc&aud=*",
          "rpc:*?aud=did:web:api.example.com%23svc&%61ud=did:web:api.example.com%23svc",
          "rpc:app.example.*?aud=*",
          "rpc:app.example.getFeed?lxm=app.example.getProfile&aud=*",
          "rpc:app.example.getFeed?aud=*&inheritAud=true",
          "rpc:?aud=*",
          "rpc?aud=*"
        ] do
      assert {:error, :invalid_scope} = Permissions.rpc(scope)
      refute Permissions.supported?(scope)
    end
  end

  test "RPC permission coverage never combines one grant's audience with another grant's method" do
    grants = %{
      "scope" =>
        "atproto rpc:app.example.getFeed?aud=did:web:a.example.com%23app rpc:app.example.getProfile?aud=did:web:b.example.com%23app"
    }

    refute ClientMetadata.scopes_allowed?(
             grants,
             "atproto rpc:app.example.getProfile?aud=did:web:a.example.com%23app"
           )

    refute ClientMetadata.scopes_allowed?(grants, "atproto rpc:app.example.getFeed?aud=*")
    refute ClientMetadata.scopes_allowed?(grants, "atproto rpc:*?aud=did:web:a.example.com%23app")

    refute Permissions.allows_rpc?(
             grants["scope"],
             "did:web:a.example.com#app",
             "app.example.getProfile"
           )

    assert Permissions.allows_rpc?(
             grants["scope"],
             "did:web:a.example.com#app",
             "app.example.getFeed"
           )

    refute Permissions.allows_rpc?(
             grants["scope"],
             "did:web:a.example.com#other",
             "app.example.getFeed"
           )

    refute Permissions.allows_rpc?(
             grants["scope"],
             "did:web:a.example.com",
             "app.example.getFeed"
           )

    refute Permissions.allows_rpc?(grants["scope"], "did:web:a.example.com#app", "*")

    broad = %{
      "scope" => "atproto rpc:*?aud=did:web:a.example.com%23app rpc:app.example.getProfile?aud=*"
    }

    assert ClientMetadata.scopes_allowed?(
             broad,
             "atproto rpc?lxm=app.example.getFeed&lxm=app.example.getProfile&aud=did:web:a.example.com%23app"
           )

    assert ClientMetadata.scopes_allowed?(
             broad,
             "atproto rpc:app.example.getProfile?aud=did:web:b.example.com%23app"
           )

    assert Permissions.allows_rpc?(broad["scope"], "did:web:a.example.com#app", "*")
    refute Permissions.write_admission?(broad["scope"], :put)
    refute Permissions.write_admission?(broad["scope"], :upload_blob)
  end
end
