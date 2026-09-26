defmodule AtollWeb.AccountStatusControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Blobs, CID, Multikey, Repo, Repositories, SigningKey}
  alias Atoll.Accounts.{Credentials, Sessions}
  alias Atoll.Repositories.Revision
  @did "did:web:status.example.com"
  @route "/xrpc/com.atproto.server.checkAccountStatus"

  setup %{conn: conn} do
    previous =
      for key <- [:session_signing_key, :identity_resolution_options],
          do: {key, Application.fetch_env(:atoll, key)}

    endpoint = Application.fetch_env!(:atoll, AtollWeb.Endpoint)

    AtollWeb.Endpoint.config_change(
      [
        {AtollWeb.Endpoint,
         Keyword.put(endpoint, :url, scheme: "https", host: "pds.example.com", port: 443)}
      ],
      []
    )

    Application.put_env(:atoll, :session_signing_key, :binary.copy(<<24>>, 32))

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
    {:ok, head} = Repositories.create(@did, key)
    {:ok, _} = Credentials.create(@did, "status test password")
    {:ok, pair} = Sessions.create(@did, "status test password")
    {:ok, public} = Multikey.encode(key.curve, key.public)

    doc = %{
      "id" => @did,
      "verificationMethod" => [
        %{
          "id" => "#atproto",
          "controller" => @did,
          "type" => "Multikey",
          "publicKeyMultibase" => public
        }
      ],
      "service" => [
        %{
          "id" => "#atproto_pds",
          "type" => "AtprotoPersonalDataServer",
          "serviceEndpoint" => "https://pds.example.com"
        }
      ]
    }

    configure(doc)
    id = rem(System.unique_integer([:positive]), 65_536)

    %{
      conn: %{conn | remote_ip: {10, 42, div(id, 256), rem(id, 256)}},
      key: key,
      head: head,
      pair: pair,
      doc: doc
    }
  end

  test "reports scoped counts, retained blocks and current root", c do
    {:ok, blob} = Blobs.stage(@did, "hello", "text/plain")

    {:ok, head} =
      Repositories.apply_writes(
        @did,
        [{:put, "com.example.record/a", %{"$type" => "com.example.record", "blob" => blob}}],
        c.key
      )

    {:ok, _} = Repositories.create("did:web:other.example.com", c.key)
    {:ok, _} = Blobs.stage("did:web:other.example.com", "other", "text/plain")
    revisions = Repo.all(Revision) |> Enum.filter(&(&1.did == @did))
    blocks = revisions |> Enum.flat_map(& &1.blocks) |> Enum.uniq() |> length()
    conn = query(c)
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    assert json_response(conn, 200) == %{
             "activated" => true,
             "validDid" => true,
             "repoCommit" => CID.to_base32(head.head),
             "repoRev" => head.rev,
             "repoBlocks" => blocks,
             "indexedRecords" => 1,
             "privateStateValues" => 0,
             "expectedBlobs" => 1,
             "importedBlobs" => 1
           }
  end

  test "inactive accounts retain status access without acquiring write permission", c do
    for status <- [:deactivated, :suspended, :takendown] do
      {:ok, _} = Repositories.set_status(@did, status)
      assert %{"activated" => false} = query(c) |> json_response(200)
      assert {:error, {:repo_inactive, ^status}} = Sessions.authenticate(c.pair.access_jwt)
    end
  end

  test "unresolved identity, mismatched service and mismatched key report invalid DID", c do
    configure(
      put_in(c.doc, ["service", Access.at(0), "serviceEndpoint"], "https://other.example.com")
    )

    assert %{"validDid" => false} = query(c) |> json_response(200)
    other = SigningKey.generate()
    {:ok, public} = Multikey.encode(other.curve, other.public)
    configure(put_in(c.doc, ["verificationMethod", Access.at(0), "publicKeyMultibase"], public))
    assert %{"validDid" => false} = query(c) |> json_response(200)

    Application.put_env(:atoll, :identity_resolution_options,
      lookup: fn _ -> {:error, :nxdomain} end
    )

    assert %{"validDid" => false} = query(c) |> json_response(200)
  end

  test "rejects missing and refresh tokens before resolution and revoked sessions after resolution",
       c do
    Application.put_env(:atoll, :identity_resolution_options,
      lookup: fn _ -> flunk("unauthorized DNS") end
    )

    assert get(c.conn, @route) |> json_response(401)
    assert query(%{c | pair: %{access_jwt: c.pair.refresh_jwt}}) |> json_response(401)
    configure(c.doc, fn -> assert {:ok, :ok} = Sessions.revoke(c.pair.refresh_jwt) end)
    assert query(c) |> json_response(401)
  end

  test "enforces query method and shared rate limits for encoded routes", c do
    assert post(c.conn, @route) |> response(405)
    for _ <- 1..300, do: Atoll.Accounts.SessionLimiter.check({:session, c.conn.remote_ip}, 300)
    assert get(c.conn, "/xrpc/com.atproto.server.%63heckAccountStatus") |> json_response(429)
  end

  defp query(c),
    do: c.conn |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt) |> get(@route)

  defp configure(doc, callback \\ fn -> :ok end) do
    Application.put_env(:atoll, :identity_resolution_options,
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
      request:
        Req.new(
          plug: fn conn ->
            callback.()
            Req.Test.json(conn, doc)
          end
        )
    )
  end
end
