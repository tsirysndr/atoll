defmodule AtollWeb.AdminDeletionControllerTest do
  use AtollWeb.ConnCase, async: false
  import Ecto.Query
  alias Atoll.Accounts.{Credentials, Deletion, Profile, Sessions}
  alias Atoll.Blobs.{Blob, Cleanup, CleanupJob}
  alias Atoll.Repositories.{Events, Head}
  alias Atoll.Moderation.Audit
  alias Atoll.{Blobs, CID, KeyVault, Repo, Repositories, SigningKey, Storage}
  @did "did:web:delete.example.com"
  @password "account deletion password"
  @secret "operator-deletion-secret-at-least-32"
  @path "/xrpc/com.atproto.admin.deleteAccount"
  setup %{conn: conn} do
    previous =
      Map.new(
        [
          :admin_password,
          :session_signing_key,
          :key_encryption_key,
          :email_worker,
          :email_delivery_options
        ],
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

    Application.put_env(:atoll, :admin_password, @secret)
    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    {:ok, _} = KeyVault.store(@did, key)
    Repo.insert!(%Profile{did: @did, handle: "delete.example.com", email: "owner@example.com"})
    {:ok, _} = Credentials.create(@did, @password)
    {:ok, pair} = Sessions.create(@did, @password)
    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 50, div(id, 256), rem(id, 256)}}, pair: pair}
  end

  test "deletion cascades local state, retains private audit, and queues shared-safe cleanup",
       c do
    other = "did:web:survivor.example.com"
    {:ok, _} = Repositories.create(other, SigningKey.generate())
    {:ok, _} = Credentials.create(other, @password)
    {:ok, survivor} = Sessions.create(other, @password)
    {:ok, shared} = Blobs.stage(@did, "shared bytes", "text/plain")
    {:ok, _} = Blobs.stage(other, "shared bytes", "text/plain")
    {:ok, unique} = Blobs.stage(@did, "unique bytes", "text/plain")

    {:ok, _} =
      Atoll.Accounts.InviteControl.set(%{"account" => @did, "note" => "retained reason"}, true)

    cursor = Events.latest_seq()
    result = auth(c.conn) |> post(@path, %{did: @did})
    assert response(result, 200) == ""
    assert get_resp_header(result, "cache-control") == ["no-store"]

    for schema <- [
          Head,
          Profile,
          Atoll.Accounts.Credential,
          Atoll.Accounts.Session,
          Atoll.Repositories.EncryptedKey,
          Blob
        ] do
      refute Repo.exists?(from r in schema, where: r.did == ^@did)
    end

    assert {:error, :invalid_token} = Sessions.authenticate(c.pair.access_jwt)
    assert {:ok, _} = Sessions.authenticate(survivor.access_jwt)
    assert {:ok, [event]} = Events.list_after(cursor)
    assert event.did == @did
    assert event.payload == %{"active" => false, "status" => "deleted"}
    assert Repo.aggregate(from(e in Atoll.Repositories.Event, where: e.did == ^@did), :count) == 1
    assert {:ok, %{entries: [prior, deleted]}} = Audit.list(100, 0, @did)
    assert prior.after["inviteNote"] == "retained reason"
    assert deleted.operation == "com.atproto.admin.deleteAccount"
    assert deleted.requested == %{"did" => @did}
    assert deleted.before == %{"availability" => "active"}
    assert deleted.after == %{"availability" => "deleted"}
    assert Repo.aggregate(CleanupJob, :count) == 2
    assert {:ok, %{deleted: 1, retained: 1}} = Cleanup.collect()
    {:ok, shared_cid} = CID.from_base32(shared["ref"]["$link"])
    {:ok, unique_cid} = CID.from_base32(unique["ref"]["$link"])
    assert {:ok, "shared bytes"} = Storage.get_block(shared_cid)
    assert {:error, :not_found} = Storage.get_block(unique_cid)

    assert auth(c.conn) |> post(@path, %{did: @did}) |> json_response(400) == %{
             "error" => "NotFound",
             "message" => "Account not found."
           }

    assert {:ok, %{entries: [^prior, ^deleted]}} = Audit.list(100, 0, @did)
  end

  test "rollback restores account, sessions, previous events, cleanup queue, and audit", c do
    {:ok, _} = Blobs.stage(@did, "rollback bytes", "text/plain")
    cursor = Events.latest_seq()

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, :deleted} = Deletion.admin_delete(%{"did" => @did})
               Repo.rollback(:cancelled)
             end)

    assert Repo.get!(Head, @did)
    assert Repo.get!(Profile, @did)
    assert {:ok, _} = Sessions.authenticate(c.pair.access_jwt)
    assert Repo.aggregate(CleanupJob, :count) == 0
    assert Events.latest_seq() == cursor
    assert {:ok, %{entries: []}} = Audit.list()
  end

  test "authorization happens before parsing and invalid requests cannot delete", c do
    assert c.conn
           |> put_req_header("content-type", "application/json")
           |> post(@path, "{")
           |> json_response(401)

    assert c.conn
           |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
           |> post(@path, %{did: @did})
           |> json_response(401)

    assert auth(c.conn) |> get(@path) |> json_response(405)

    for params <- [
          %{},
          %{did: "bad"},
          %{did: @did, extra: true},
          %{did: "did:web:missing.example.com"}
        ] do
      assert auth(c.conn) |> post(@path, params) |> json_response(400)
    end

    assert Repo.get!(Head, @did)
    assert {:ok, %{entries: []}} = Audit.list()
  end

  test "operator can remove inactive repositories, including incomplete provisioning", c do
    for status <- [:deactivated, :takendown, :suspended] do
      did = "did:web:#{status}.example.com"
      {:ok, _} = Repositories.create(did, SigningKey.generate())
      {:ok, _} = Repositories.set_status(did, status)
      assert response(auth(c.conn) |> post(@path, %{did: did}), 200) == ""
      refute Repo.get(Head, did)
      assert {:ok, %{entries: [entry]}} = Audit.list(100, 0, did)
      assert entry.before == %{"availability" => Atom.to_string(status)}
    end

    assert Repo.get!(Head, @did)
  end

  defp auth(conn),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Basic " <> Base.encode64("admin:" <> @secret))
end
