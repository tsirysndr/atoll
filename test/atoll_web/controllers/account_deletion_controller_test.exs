defmodule AtollWeb.AccountDeletionControllerTest do
  use AtollWeb.ConnCase, async: false
  import Ecto.Query
  alias Atoll.Accounts.{AppPasswords, Credentials, Deletion, Profile, Sessions}
  alias Atoll.Blobs.{Blob, Cleanup, CleanupJob}
  alias Atoll.Repositories.{Events, Head}
  alias Atoll.{Blobs, CID, KeyVault, Repo, Repositories, SigningKey, Storage}
  @did "did:web:delete.example.com"
  @password "account deletion password"
  @prefix "/xrpc/com.atproto.server."

  setup %{conn: conn} do
    previous =
      Map.new(
        [:session_signing_key, :key_encryption_key, :email_worker, :email_delivery_options],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    for key <- [:session_signing_key, :key_encryption_key],
        do: Application.put_env(:atoll, key, :binary.copy(<<36>>, 32))

    Application.put_env(:atoll, :email_worker,
      url: "https://worker.example.com/send",
      token: "secret"
    )

    Application.put_env(:atoll, :email_delivery_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    {:ok, _} = KeyVault.store(@did, key)
    Repo.insert!(%Profile{did: @did, handle: "delete.example.com", email: "owner@example.com"})
    {:ok, _} = Credentials.create(@did, @password)
    {:ok, pair} = Sessions.create(@did, @password)
    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 50, div(id, 256), rem(id, 256)}}, pair: pair}
  end

  test "atomically withdraws account data, preserves other owners, and emits a deletion event",
       c do
    other = "did:web:survivor.example.com"
    {:ok, _} = Repositories.create(other, SigningKey.generate())
    {:ok, _} = Credentials.create(other, @password)
    {:ok, other_session} = Sessions.create(other, @password)
    {:ok, shared} = Blobs.stage(@did, "shared bytes", "text/plain")
    {:ok, _} = Blobs.stage(other, "shared bytes", "text/plain")
    {:ok, unique} = Blobs.stage(@did, "private bytes", "text/plain")
    record = %{"$type" => "com.example.note", "blob" => shared}

    written =
      c.conn
      |> auth(c.pair.access_jwt)
      |> json_post("/xrpc/com.atproto.repo.createRecord", %{
        repo: @did,
        collection: "com.example.note",
        record: record
      })

    assert response(written, 200)
    {:ok, app} = AppPasswords.create(c.pair.access_jwt, %{"name" => "client"})
    {:ok, app_session} = Sessions.create(@did, app.password)
    # A harmless operator decision still has a private audit record after deletion.
    assert {:ok, _} =
             Atoll.Accounts.SubjectStatus.update(%{
               "subject" => %{"$type" => "com.atproto.admin.defs#repoRef", "did" => @did}
             })

    {:ok, audit_before} = Atoll.Moderation.Audit.list(100, 0, @did)
    assert length(audit_before.entries) == 1
    code = deletion_code(c)
    cursor = Events.latest_seq()
    assert response(delete_account(c, code), 200) == ""
    assert is_nil(Repo.get(Head, @did))
    assert is_nil(Repo.get(Profile, @did))
    assert Atoll.Moderation.Audit.list(100, 0, @did) == {:ok, audit_before}

    for schema <- [
          Atoll.Accounts.Credential,
          Atoll.Accounts.Session,
          Atoll.Accounts.AppPassword,
          Atoll.Repositories.Record,
          Atoll.Repositories.Revision,
          Atoll.Repositories.EncryptedKey,
          Atoll.Blobs.Reference,
          Blob
        ] do
      refute Repo.exists?(from r in schema, where: r.did == ^@did)
    end

    assert {:error, :invalid_token} = Sessions.authenticate(c.pair.access_jwt)
    assert {:error, :invalid_token} = Sessions.authenticate(app_session.access_jwt)
    assert {:ok, _} = Sessions.authenticate(other_session.access_jwt)
    assert {:ok, [event]} = Events.list_after(cursor)
    assert event.did == @did
    assert event.payload == %{"active" => false, "status" => "deleted"}
    assert {:ok, {:frame, _, _}} = Events.next_frame(cursor)
    assert Repo.aggregate(from(e in Atoll.Repositories.Event, where: e.did == ^@did), :count) == 1
    assert Repo.aggregate(CleanupJob, :count) == 2
    assert {:ok, %{deleted: 1, retained: 1}} = Cleanup.collect()
    {:ok, shared_cid} = CID.from_base32(shared["ref"]["$link"])
    {:ok, unique_cid} = CID.from_base32(unique["ref"]["$link"])
    assert {:ok, "shared bytes"} = Storage.get_block(shared_cid)
    assert {:error, :not_found} = Storage.get_block(unique_cid)
    assert response(delete_account(c, code), 401)
  end

  test "requires full-session email request and the account password plus correct code", c do
    {:ok, app} = AppPasswords.create(c.pair.access_jwt, %{"name" => "app"})
    {:ok, app_session} = Sessions.create(@did, app.password)
    assert response(post(c.conn, @prefix <> "requestAccountDelete"), 401)

    assert response(
             c.conn |> auth(app_session.access_jwt) |> post(@prefix <> "requestAccountDelete"),
             403
           )

    code = deletion_code(c)
    assert response(delete_account(c, code, app.password), 401)
    assert response(delete_account(c, code, "incorrect password"), 401)
    assert response(delete_account(c, String.duplicate("x", 32)), 400)
    assert Repo.get!(Head, @did)
    assert Repo.aggregate(CleanupJob, :count) == 0
    assert response(delete_account(c, code), 200) == ""
  end

  test "expired tokens and address changes cannot authorize deletion", c do
    code = deletion_code(c)
    change(deletion_expires_at: System.system_time(:second) - 1)
    assert json_response(delete_account(c, code), 400)["error"] == "ExpiredToken"

    assert {:ok, _} =
             Atoll.Accounts.EmailUpdate.update(c.pair.access_jwt, %{
               "email" => "changed@example.com"
             })

    assert is_nil(Repo.get!(Profile, @did).deletion_digest)
    assert json_response(delete_account(c, code), 400)["error"] == "InvalidToken"
  end

  test "password recovery clears outstanding deletion authorization", c do
    code = deletion_code(c)
    expect_code()

    assert {:ok, :requested} =
             Atoll.Accounts.PasswordReset.request(%{"email" => "owner@example.com"})

    assert_receive {:code, recovery}

    assert {:ok, :reset} =
             Atoll.Accounts.PasswordReset.reset(%{
               "token" => recovery,
               "password" => "new deletion password"
             })

    assert response(delete_account(c, code, "new deletion password"), 400)
    assert Repo.get!(Head, @did)
  end

  test "existing full sessions can request deletion of taken-down accounts", c do
    {:ok, _} = Repositories.set_status(@did, :takendown)
    code = deletion_code(c)
    assert response(delete_account(c, code), 200) == ""
  end

  test "delivery failures, persistent cooldown and malformed HTTP requests do not delete", c do
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 503, "private"))

    assert response(
             c.conn |> auth(c.pair.access_jwt) |> post(@prefix <> "requestAccountDelete"),
             503
           )

    assert response(
             c.conn |> auth(c.pair.access_jwt) |> post(@prefix <> "requestAccountDelete"),
             429
           )

    assert response(get(c.conn, @prefix <> "deleteAccount"), 405)
    assert response(json_post(c.conn, @prefix <> "deleteAccount", %{did: @did}), 400)

    assert response(
             c.conn
             |> put_req_header("content-type", "application/json")
             |> post(@prefix <> "deleteAccount", String.duplicate("x", 4097)),
             413
           )

    assert Repo.get!(Head, @did)
    assert {:error, :invalid_request} = Deletion.delete(%{})
  end

  defp deletion_code(c) do
    expect_code()

    assert response(
             c.conn |> auth(c.pair.access_jwt) |> post(@prefix <> "requestAccountDelete"),
             200
           ) == ""

    assert_receive {:code, code}
    code
  end

  defp expect_code do
    parent = self()

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      message = Jason.decode!(body)
      assert message["to"] == "owner@example.com"
      [_, code] = Regex.run(~r/code is: ([A-Za-z0-9_-]{32})/, message["text"])
      send(parent, {:code, code})
      Plug.Conn.send_resp(conn, 202, "")
    end)
  end

  defp change(attrs),
    do: Repo.get!(Profile, @did) |> Ecto.Changeset.change(attrs) |> Repo.update!()

  defp delete_account(c, code, password \\ @password),
    do:
      json_post(c.conn, @prefix <> "deleteAccount", %{did: @did, password: password, token: code})

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp json_post(conn, path, params),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(params))
end
