defmodule AtollWeb.AccountMigrationControllerTest do
  use AtollWeb.ConnCase, async: false

  alias Atoll.{
    CAR,
    CBOR,
    CID,
    Commit,
    KeyVault,
    MST,
    Multikey,
    Repo,
    Repositories,
    SigningKey,
    TID
  }

  alias Atoll.Accounts.{Credentials, Profile, ServiceTokenUse, Sessions}
  @did "did:web:migrant.example.com"
  @handle "migrant.example.com"
  @create "/xrpc/com.atproto.server.createAccount"
  @import "/xrpc/com.atproto.repo.importRepo"
  @recommended "/xrpc/com.atproto.identity.getRecommendedDidCredentials"
  @password "migrating account password"

  setup %{conn: conn} do
    previous =
      Map.new(
        [
          :session_signing_key,
          :key_encryption_key,
          :identity_resolution_options,
          :invite_code_required
        ],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    Application.put_env(:atoll, :invite_code_required, false)

    endpoint = Application.fetch_env!(:atoll, AtollWeb.Endpoint)

    AtollWeb.Endpoint.config_change(
      [
        {AtollWeb.Endpoint,
         Keyword.put(endpoint, :url, scheme: "https", host: "new-pds.example.com", port: 443)}
      ],
      []
    )

    for key <- [:session_signing_key, :key_encryption_key],
        do: Application.put_env(:atoll, key, :binary.copy(<<28>>, 32))

    on_exit(fn ->
      AtollWeb.Endpoint.config_change([{AtollWeb.Endpoint, endpoint}], [])

      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    key = SigningKey.generate()
    doc = document(@did, @handle, key, "https://old-pds.example.com")
    configure(doc)
    {:ok, old_rev} = TID.next()
    {:ok, rev} = TID.next(old_rev)
    id = rem(System.unique_integer([:positive]), 65_536)

    %{
      conn: %{conn | remote_ip: {10, 45, div(id, 256), rem(id, 256)}},
      source: key,
      doc: doc,
      rev: rev,
      old_rev: old_rev
    }
  end

  test "migrates an existing DID across signing keys and activates after the DID update", c do
    pair = create(c) |> json_response(200)
    assert pair["did"] == @did
    assert pair["handle"] == @handle
    assert pair["active"] == false
    assert {:ok, _} = Credentials.verify(@did, @password)
    assert {:ok, %{status: :deactivated} = initial} = Repositories.get_head(@did)
    refute initial.public_key == c.source.public
    profile = Repo.get!(Profile, @did)
    assert profile.email == "owner@example.com"
    assert profile.import_public_key == c.source.public
    auth = bearer(c.conn, pair["accessJwt"])
    rec = auth |> get(@recommended) |> json_response(200)
    assert rec["alsoKnownAs"] == ["at://" <> @handle]
    assert rec["services"]["atproto_pds"]["endpoint"] == "https://new-pds.example.com"
    {:ok, new_key} = Multikey.from_did_key(rec["verificationMethods"]["atproto"])
    assert new_key.public == initial.public_key
    refute Map.has_key?(rec, "rotationKeys")

    {archive, old_commit} = archive(c, c.rev)
    {foreign, _} = archive(%{c | source: SigningKey.generate()}, c.rev)
    assert upload(auth, foreign) |> json_response(400)
    assert upload(auth, archive) |> response(200) == ""
    {:ok, imported} = Repositories.get_head(@did)
    assert imported.rev > initial.rev
    refute imported.head == old_commit.cid
    seq = Atoll.Repositories.Events.latest_seq()
    assert upload(auth, archive) |> response(200) == ""
    assert Atoll.Repositories.Events.latest_seq() == seq
    {stale, _} = archive(c, c.old_rev)
    assert upload(auth, stale) |> json_response(400)
    assert auth |> post("/xrpc/com.atproto.server.activateAccount") |> json_response(400)

    {:ok, local_key} = KeyVault.fetch(@did)
    configure(document(@did, @handle, local_key, "https://new-pds.example.com"))
    assert auth |> post("/xrpc/com.atproto.server.activateAccount") |> response(200) == ""
    assert Repo.get!(Profile, @did).import_public_key == nil
    assert Repo.get!(Profile, @did).import_head == nil

    assert {:ok, %{value: %{"text" => "source data"}}} =
             Repositories.get_record(@did, "com.example.record/one")

    {:ok, exported} = Repositories.export(@did)
    {:ok, %{roots: [root], blocks: blocks}} = CAR.decode(exported)
    assert {:ok, _} = Commit.verify(blocks[root], @did, new_key.curve, new_key.public)
    assert upload(auth, archive) |> json_response(400)
    assert {:ok, %{did: @did}} = Sessions.authenticate(pair["accessJwt"])
  end

  test "migration requires an invitation when configured and failed provisioning preserves it",
       c do
    alias Atoll.Accounts.{Invite, InviteUse, Invites}
    Application.put_env(:atoll, :invite_code_required, true)
    token = service_token(c.source)
    assert json_response(create(c, %{}, token), 400)["error"] == "InvalidInviteCode"
    refute Repo.exists?(ServiceTokenUse)
    {:ok, %{code: code}} = Invites.create()
    Application.delete_env(:atoll, :key_encryption_key)
    assert json_response(create(c, %{"inviteCode" => code}, token), 503)
    assert Repo.get!(Invite, code).remaining == 1
    refute Repo.exists?(InviteUse)
    refute Repo.exists?(ServiceTokenUse)
    Application.put_env(:atoll, :key_encryption_key, :binary.copy(<<28>>, 32))
    assert json_response(create(c, %{"inviteCode" => code}, token), 200)["did"] == @did
    assert Repo.get!(Invite, code).remaining == 0
    assert Repo.get!(InviteUse, @did).code == code
  end

  test "provisioning failure rolls back the repository, credentials, profile and token use", c do
    token = service_token(c.source)
    Application.delete_env(:atoll, :key_encryption_key)
    assert create(c, %{}, token) |> json_response(503)
    assert {:error, :not_found} = Repositories.get_head(@did)
    refute Repo.get(Profile, @did)
    refute Repo.exists?(ServiceTokenUse)
    assert Repo.aggregate(Atoll.Storage.Block, :count) == 0
    Application.put_env(:atoll, :key_encryption_key, :binary.copy(<<28>>, 32))
    assert create(c, %{}, token) |> json_response(200)
    assert %{"error" => "InvalidToken"} = create(c, %{}, token) |> json_response(401)
    assert Repo.aggregate(Profile, :count) == 1
  end

  test "rejects duplicate accounts and handles without overwriting existing data", c do
    assert create(c) |> json_response(200)
    {:ok, original} = Repositories.get_head(@did)
    assert create(c) |> json_response(400)
    other = "did:web:other.example.com"
    configure(document(other, @handle, c.source, "https://old-pds.example.com"))

    assert %{"error" => "HandleNotAvailable"} =
             create(c, %{did: other}, service_token(c.source, other)) |> json_response(400)

    assert Repositories.get_head(@did) == {:ok, original}
    assert {:error, :not_found} = Repositories.get_head(other)
    assert Repo.aggregate(ServiceTokenUse, :count) == 1

    configure(document(other, "other.example.com", c.source, "https://old-pds.example.com"))

    assert %{"error" => "InvalidRequest"} =
             create(c, %{did: other, handle: "other.example.com"}, service_token(c.source, other))
             |> json_response(400)

    assert {:error, :not_found} = Repositories.get_head(other)
    assert Repo.aggregate(ServiceTokenUse, :count) == 1
  end

  test "accepts the explicit PDS service audience and protects recommended credentials", c do
    assert create(c, %{}, service_token(c.source, @did, "#atproto_pds")) |> json_response(200)
    assert get(c.conn, @recommended) |> json_response(401)
    assert post(c.conn, @recommended) |> response(405)
  end

  test "requires matching service authorization, verified handles, bounded valid inputs", c do
    assert c.conn
           |> put_req_header("content-type", "application/json")
           |> post(@create, input())
           |> json_response(401)

    assert create(c, %{did: "did:web:someone.example.com"}) |> json_response(403)

    for changes <- [
          %{password: "short"},
          %{handle: "bad"},
          %{email: "a b@example.com"},
          %{email: "a..b@example.com"},
          %{plcOp: %{}}
        ] do
      assert create(c, changes) |> json_response(400)
    end

    configure(Map.put(c.doc, "alsoKnownAs", []))
    assert create(c) |> json_response(400)
    refute Repo.exists?(Profile)
    refute Repo.exists?(ServiceTokenUse)
    assert get(c.conn, @create) |> response(405)

    assert c.conn
           |> put_req_header("content-type", "application/json")
           |> post(@create, String.duplicate("x", 4097))
           |> json_response(413)
  end

  test "rejects multi-root CAR imports", c do
    pair = create(c) |> json_response(200)
    {archive, commit} = archive(c, c.rev)
    {:ok, %{blocks: blocks}} = CAR.decode(archive)
    {:ok, bad} = CAR.encode([commit.cid, commit.cid], blocks)
    assert upload(bearer(c.conn, pair["accessJwt"]), bad) |> json_response(400)
  end

  defp input, do: %{did: @did, handle: @handle, email: "Owner@Example.COM", password: @password}

  defp create(c, changes \\ %{}, token \\ nil),
    do:
      c.conn
      |> bearer(token || service_token(c.source))
      |> put_req_header("content-type", "application/json")
      |> post(@create, Map.merge(input(), changes))

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp upload(conn, bytes),
    do:
      conn
      |> put_req_header("content-type", "application/vnd.ipld.car")
      |> put_req_header("content-length", Integer.to_string(byte_size(bytes)))
      |> post(@import, bytes)

  defp document(did, handle, key, pds) do
    {:ok, encoded} = Multikey.encode(key.curve, key.public)

    %{
      "id" => did,
      "alsoKnownAs" => ["at://" <> handle],
      "verificationMethod" => [
        %{
          "id" => "#atproto",
          "controller" => did,
          "type" => "Multikey",
          "publicKeyMultibase" => encoded
        }
      ],
      "service" => [
        %{"id" => "#atproto_pds", "type" => "AtprotoPersonalDataServer", "serviceEndpoint" => pds}
      ]
    }
  end

  defp configure(doc) do
    Application.put_env(:atoll, :identity_resolution_options,
      txt_lookup: fn _ -> [["did=" <> doc["id"]]] end,
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
      request: Req.new(plug: fn conn -> Req.Test.json(conn, doc) end)
    )
  end

  defp service_token(key, did \\ @did, service \\ "") do
    now = System.system_time(:second)

    claims = %{
      iss: did,
      aud: Application.fetch_env!(:atoll, :pds)[:did] <> service,
      iat: now,
      exp: now + 60,
      jti: Base.encode16(:crypto.strong_rand_bytes(16)),
      lxm: "com.atproto.server.createAccount"
    }

    header = %{alg: "ES256K", typ: "JWT"}
    encode = fn data -> data |> Jason.encode!() |> Base.url_encode64(padding: false) end
    input = encode.(header) <> "." <> encode.(claims)
    {:ok, sig} = SigningKey.sign(key, input)
    input <> "." <> Base.url_encode64(sig, padding: false)
  end

  defp archive(c, rev) do
    value = CBOR.encode!(%{"$type" => "com.example.record", "text" => "source data"})
    cid = CID.create(value, :dag_cbor)
    {:ok, tree} = MST.new(%{"com.example.record/one" => cid})
    {:ok, commit} = Commit.create(@did, tree.root, rev, c.source)

    {:ok, archive} =
      CAR.encode(
        [commit.cid],
        tree.blocks |> Map.put(cid, value) |> Map.put(commit.cid, commit.bytes)
      )

    {archive, commit}
  end
end
