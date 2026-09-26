defmodule AtollWeb.OAuthRecordWriteTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.OAuth.{Nonce, PAR, AuthorizationCodes, Session, AccessToken, Resource}
  alias Atoll.{Repo, Repositories}
  alias Atoll.Accounts.Sessions
  @id "https://app.example.com/metadata.json"

  setup %{conn: conn} do
    for name <- [
          :oauth_nonce_secret,
          :oauth_transport_options,
          :key_encryption_key,
          :network_lexicons_enabled,
          :lexicon_resolution_options,
          :blob_storage,
          :blob_quota
        ] do
      prior = Application.fetch_env(:atoll, name)

      on_exit(fn ->
        case prior do
          {:ok, value} -> Application.put_env(:atoll, name, value)
          :error -> Application.delete_env(:atoll, name)
        end
      end)
    end

    Application.put_env(:atoll, :oauth_nonce_secret, :crypto.strong_rand_bytes(32))

    metadata = %{
      "client_id" => @id,
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "scope" => "atproto transition:generic transition:email",
      "redirect_uris" => ["https://app.example.com/callback"],
      "dpop_bound_access_tokens" => true
    }

    transport(metadata)
    {:ok, nonce} = Nonce.issue(:authorization)
    id = rem(System.unique_integer([:positive]), 65_536)

    c = %{
      conn: %{conn | remote_ip: {10, 80, div(id, 256), rem(id, 256)}},
      key: JOSE.JWK.generate_key({:ec, :secp256r1}),
      nonce: nonce,
      metadata: metadata
    }

    verifier = random()

    params = %{
      "client_id" => @id,
      "response_type" => "code",
      "redirect_uri" => "https://app.example.com/callback",
      "scope" => "atproto transition:generic transition:email",
      "state" => "private-state",
      "code_challenge_method" => "S256",
      "code_challenge" => :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    }

    did = "did:plc:httptoken"
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    {:ok, _} = Repositories.create_managed(did)
    session_options = [secret: :crypto.strong_rand_bytes(32), audience: "did:web:pds.example.com"]
    {:ok, pair} = Sessions.create_for_account(did, session_options)

    {:ok, %{request_uri: uri}} =
      PAR.push(
        params,
        [proof(c, "/oauth/par")],
        Keyword.put(
          Application.fetch_env!(:atoll, :oauth_transport_options),
          :session_options,
          session_options
        )
      )

    {:ok, approved} =
      AuthorizationCodes.decide(
        pair.access_jwt,
        @id,
        uri,
        {:approve, "atproto transition:generic transition:email"},
        Keyword.put(
          Application.fetch_env!(:atoll, :oauth_transport_options),
          :session_options,
          session_options
        )
      )

    # Setup deliberately exercises metadata retrieval; assertions below concern HTTP work only.
    assert_received :metadata_fetched
    assert_received :metadata_fetched

    c =
      Map.merge(c, %{
        did: did,
        params: %{
          "grant_type" => "authorization_code",
          "client_id" => @id,
          "code" => approved.code,
          "redirect_uri" => params["redirect_uri"],
          "code_verifier" => verifier
        }
      })

    tokens = send_form(c, URI.encode_query(c.params)) |> json_response(200)

    Repo.insert!(%Atoll.Accounts.Profile{
      did: did,
      handle: "account.example.com",
      email: "private@example.com",
      email_confirmed_at: DateTime.utc_now(),
      email_auth_factor: true
    })

    {:ok, resource_nonce} = Nonce.issue(:resource)
    Map.merge(c, %{tokens: tokens, resource_nonce: resource_nonce})
  end

  test "generic scope writes create, put, delete and atomic batches", c do
    created = write(c, "createRecord", body(c, "one")) |> json_response(200)
    assert created["uri"] == "at://#{c.did}/com.example.record/one"

    updated =
      write(c, "putRecord", Map.put(body(c, "one"), "swapRecord", created["cid"]))
      |> json_response(200)

    assert updated["uri"] == created["uri"]

    batch = %{
      "repo" => c.did,
      "writes" => [
        %{
          "$type" => "com.atproto.repo.applyWrites#create",
          "collection" => "com.example.record",
          "rkey" => "two",
          "value" => %{"$type" => "com.example.record", "text" => "two"}
        },
        %{
          "$type" => "com.atproto.repo.applyWrites#delete",
          "collection" => "com.example.record",
          "rkey" => "one"
        }
      ]
    }

    assert write(c, "applyWrites", batch)
           |> json_response(200)
           |> Map.fetch!("results")
           |> length() == 2

    assert {:error, :not_found} = Repositories.get_record(c.did, "com.example.record/one")
    assert write(c, "deleteRecord", Map.drop(body(c, "two"), ["record"])) |> json_response(200)
    assert {:error, :not_found} = Repositories.get_record(c.did, "com.example.record/two")
  end

  test "a narrowed token cannot borrow generic scope from its session", c do
    token = Repo.get!(AccessToken, :crypto.hash(:sha256, c.tokens["access_token"]))
    token |> Ecto.Changeset.change(scope: "atproto transition:email") |> Repo.update!()
    result = write(c, "putRecord", body(c, "denied"))
    assert json_response(result, 403) == %{"error" => "insufficient_scope"}
    assert get_resp_header(result, "www-authenticate") |> hd() =~ "insufficient_scope"
    assert get_resp_header(result, "dpop-nonce") != []
    assert {:error, :not_found} = Repositories.get_record(c.did, "com.example.record/denied")
  end

  test "ownership, validation and swap constraints still reject mutation", c do
    {:ok, _} = Repositories.create_managed("did:plc:otheroauthrepo")
    seq = Atoll.Repositories.Events.latest_seq()

    assert write(c, "putRecord", Map.put(body(c, "foreign"), "repo", "did:plc:otheroauthrepo")).status ==
             403

    invalid = %{
      "repo" => c.did,
      "collection" => "app.bsky.graph.follow",
      "rkey" => "bad",
      "record" => %{"$type" => "app.bsky.graph.follow"},
      "validate" => true
    }

    assert write(c, "putRecord", invalid).status == 400
    {:ok, head} = Repositories.get_head("did:plc:otheroauthrepo")

    assert write(
             c,
             "putRecord",
             Map.put(body(c, "swap"), "swapCommit", Atoll.CID.to_base32(head.head))
           ).status == 400

    assert Atoll.Repositories.Events.latest_seq() == seq
  end

  test "a failed batch rolls back earlier operations and its proof remains consumed", c do
    params = %{
      "repo" => c.did,
      "writes" => [
        %{
          "$type" => "com.atproto.repo.applyWrites#create",
          "collection" => "com.example.record",
          "rkey" => "first",
          "value" => %{"$type" => "com.example.record"}
        },
        %{
          "$type" => "com.atproto.repo.applyWrites#update",
          "collection" => "com.example.record",
          "rkey" => "missing",
          "value" => %{"$type" => "com.example.record"}
        }
      ]
    }

    signed = write_proof(c, "applyWrites")
    seq = Atoll.Repositories.Events.latest_seq()
    assert write(c, "applyWrites", params, signed).status == 400
    assert {:error, :not_found} = Repositories.get_record(c.did, "com.example.record/first")
    assert Atoll.Repositories.Events.latest_seq() == seq

    assert write(c, "applyWrites", params, signed) |> json_response(401) == %{
             "error" => "invalid_dpop_proof"
           }
  end

  test "revocation during schema lookup is rechecked under the write locks", c do
    Application.put_env(:atoll, :network_lexicons_enabled, true)

    Application.put_env(:atoll, :lexicon_resolution_options,
      fetch: fn _, _ ->
        Repo.delete_all(Session)
        {:error, :lexicon_not_found}
      end
    )

    assert write(c, "putRecord", body(c, "revoked")) |> json_response(401) == %{
             "error" => "invalid_token"
           }

    assert {:error, :not_found} = Repositories.get_record(c.did, "com.example.record/revoked")
  end

  test "scope removal during schema lookup also blocks mutation", c do
    Application.put_env(:atoll, :network_lexicons_enabled, true)

    Application.put_env(:atoll, :lexicon_resolution_options,
      fetch: fn _, _ ->
        Repo.update_all(AccessToken, set: [scope: "atproto"])
        {:error, :lexicon_not_found}
      end
    )

    assert write(c, "putRecord", body(c, "narrowed")) |> json_response(403) == %{
             "error" => "insufficient_scope"
           }

    assert {:error, :not_found} = Repositories.get_record(c.did, "com.example.record/narrowed")
  end

  test "internal credentials cannot change method, process or signature", c do
    token = c.tokens["access_token"]
    url = AtollWeb.Endpoint.url() <> "/xrpc/com.atproto.repo.putRecord"
    assert {:ok, credential} = Resource.prepare_write(token, [write_proof(c, "putRecord")], url)
    assert {:ok, _} = Resource.recheck(credential, :put)
    assert {:error, :invalid_token} = Resource.recheck(credential, :delete)

    assert {:error, :invalid_token} =
             Resource.recheck(%{credential | receipt: credential.receipt <> "x"}, :put)

    refute inspect(credential) =~ credential.receipt

    secret =
      :crypto.mac(
        :hmac,
        :sha256,
        Application.fetch_env!(:atoll, :oauth_nonce_secret),
        "atoll.oauth.write-credential.v1"
      )

    {:ok, encoded} = Plug.Crypto.MessageVerifier.verify(credential.receipt, secret)

    expired =
      encoded
      |> Jason.decode!()
      |> Map.put("expires", 1)
      |> Jason.encode!()
      |> Plug.Crypto.MessageVerifier.sign(secret)

    assert {:error, :invalid_token} = Resource.recheck(%{credential | receipt: expired}, :put)
    supervisor = start_supervised!(Task.Supervisor)
    task = Task.Supervisor.async_nolink(supervisor, fn -> Resource.recheck(credential, :put) end)
    assert Task.await(task) == {:error, :invalid_token}
    Repo.delete_all(Session)
    assert {:error, :invalid_token} = Resource.recheck(credential, :put)
  end

  test "invalid proofs are rejected before body parsing and oversized bodies consume their proof",
       c do
    signed = write_proof(c, "putRecord")

    conn =
      c.conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "DPoP " <> c.tokens["access_token"])

    assert conn
           |> put_req_header("dpop", "bad")
           |> post("/xrpc/com.atproto.repo.putRecord", "not-json")
           |> json_response(401) == %{"error" => "use_dpop_nonce"}

    oversized = String.duplicate("x", 2 * 1024 * 1024 + 1)

    assert conn
           |> put_req_header("dpop", signed)
           |> post("/xrpc/com.atproto.repo.putRecord", oversized)
           |> response(413)

    assert write(c, "putRecord", body(c, "replay"), signed) |> json_response(401) == %{
             "error" => "invalid_dpop_proof"
           }
  end

  test "OAuth uploads preserve raw bytes and staged visibility, then records publish them", c do
    bytes = <<0, 255, 128>>
    result = upload_blob(c, bytes)
    blob = json_response(result, 200)["blob"]
    cid = Atoll.CID.create(bytes, :raw)
    assert blob["ref"]["$link"] == Atoll.CID.to_base32(cid)
    assert blob["size"] == 3
    assert get_resp_header(result, "dpop-nonce") != []
    assert get_resp_header(result, "cache-control") == ["no-store"]
    assert {:ok, %{bytes: ^bytes}} = Atoll.Blobs.get_staged(c.did, cid)
    assert {:error, :blob_not_found} = Atoll.Blobs.get_public(c.did, cid)
    params = put_in(body(c, "media"), ["record", "blob"], blob)
    assert write(c, "putRecord", params) |> json_response(200)
    assert {:ok, %{bytes: ^bytes}} = Atoll.Blobs.get_public(c.did, cid)
  end

  test "upload authorization precedes size validation and consumes failed request proofs", c do
    conn = put_req_header(c.conn, "content-length", "5242881")

    assert upload_blob(%{c | conn: conn}, "x", "bad") |> json_response(401) ==
             %{"error" => "use_dpop_nonce"}

    signed = write_proof(c, "uploadBlob")
    assert upload_blob(%{c | conn: conn}, "x", signed).status == 413

    assert upload_blob(c, "x", signed) |> json_response(401) ==
             %{"error" => "invalid_dpop_proof"}

    Repo.update_all(AccessToken, set: [scope: "atproto transition:email"])

    assert upload_blob(%{c | conn: conn}, "x") |> json_response(403) ==
             %{"error" => "insufficient_scope"}

    assert Repo.aggregate(Atoll.Blobs.Blob, :count) == 0
  end

  test "upload credentials cannot authorize records and recheck revocation after body reads", c do
    for change <- [:scope, :revoked] do
      # Exercise the actual pre-parser plug, then change authorization before the controller.
      conn =
        Plug.Test.conn(:post, "/xrpc/com.atproto.repo.uploadBlob", "private upload")
        |> put_req_header("authorization", "DPoP " <> c.tokens["access_token"])
        |> put_req_header("dpop", write_proof(c, "uploadBlob"))
        |> AtollWeb.BlobUploadPlug.call([])

      refute conn.halted
      credential = conn.private.atoll_blob_upload.token
      assert {:error, :invalid_token} = Resource.recheck(credential, :put)

      assert {:error, :invalid_token} =
               Atoll.Repositories.Writes.write(credential, :put, body(c, "wrong-method"))

      expected =
        case change do
          :scope ->
            Repo.update_all(AccessToken, set: [scope: "atproto"])
            {403, "insufficient_scope"}

          :revoked ->
            Repo.delete_all(Session)
            {401, "invalid_token"}
        end

      {status, error} = expected

      assert AtollWeb.BlobController.upload(conn, %{}) |> json_response(status) == %{
               "error" => error
             }

      assert Repo.aggregate(Atoll.Blobs.Blob, :count) == 0
      Repo.update_all(AccessToken, set: [scope: "atproto transition:generic"])
    end
  end

  test "OAuth blob quotas and S3 failures retain existing storage guarantees", c do
    Application.put_env(:atoll, :blob_quota, max_bytes: 1)
    assert upload_blob(c, "too large").status == 400
    Application.put_env(:atoll, :blob_quota, max_bytes: 100)
    parent = self()

    config = [
      backend: :s3,
      s3: [
        endpoint: "https://s3.example.com",
        bucket: "test-bucket",
        region: "us-east-1",
        access_key_id: "test",
        secret_access_key: "secret",
        request:
          Req.new(
            plug: fn conn ->
              send(parent, {:s3_upload, conn.method})
              Plug.Conn.send_resp(conn, 503, "unavailable")
            end
          )
      ]
    ]

    Application.put_env(:atoll, :blob_storage, config)
    signed = write_proof(c, "uploadBlob")
    assert upload_blob(c, "bytes", signed).status == 503
    assert_received {:s3_upload, "PUT"}
    assert Repo.aggregate(Atoll.Blobs.Blob, :count) == 0

    assert upload_blob(c, "bytes", signed) |> json_response(401) ==
             %{"error" => "invalid_dpop_proof"}

    config =
      put_in(
        config,
        [:s3, :request],
        Req.new(
          plug: fn conn ->
            Plug.Conn.send_resp(conn, 200, "")
          end
        )
      )

    Application.put_env(:atoll, :blob_storage, config)
    assert upload_blob(c, "bytes") |> json_response(200)
    assert Repo.one!(Atoll.Blobs.Blob).backend == :s3
  end

  defp upload_blob(c, bytes, signed \\ nil),
    do:
      c.conn
      |> put_req_header("authorization", "DPoP " <> c.tokens["access_token"])
      |> put_req_header("dpop", signed || write_proof(c, "uploadBlob"))
      |> put_req_header("content-type", "application/octet-stream")
      |> post("/xrpc/com.atproto.repo.uploadBlob", bytes)

  defp body(c, key),
    do: %{
      "repo" => c.did,
      "collection" => "com.example.record",
      "rkey" => key,
      "record" => %{"$type" => "com.example.record", "text" => "hello"}
    }

  defp write(c, method, body, signed \\ nil),
    do:
      c.conn
      |> put_req_header("authorization", "DPoP " <> c.tokens["access_token"])
      |> put_req_header("dpop", signed || write_proof(c, method))
      |> put_req_header("content-type", "application/json")
      |> post("/xrpc/com.atproto.repo." <> method, Jason.encode!(body))

  defp write_proof(c, method) do
    {_, public} = JOSE.JWK.to_public_map(c.key)

    JOSE.JWT.sign(c.key, %{"alg" => "ES256", "typ" => "dpop+jwt", "jwk" => public}, %{
      "jti" => random(),
      "iat" => System.system_time(:second),
      "nonce" => c.resource_nonce,
      "htm" => "POST",
      "htu" => AtollWeb.Endpoint.url() <> "/xrpc/com.atproto.repo." <> method,
      "ath" =>
        :crypto.hash(:sha256, c.tokens["access_token"]) |> Base.url_encode64(padding: false)
    })
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp transport(metadata) do
    parent = self()

    Application.put_env(:atoll, :oauth_transport_options,
      request:
        Req.new(
          plug: fn conn ->
            send(parent, :metadata_fetched)
            Req.Test.json(conn, metadata)
          end
        ),
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end
    )
  end

  defp send_form(c, body, path \\ "/oauth/token"),
    do:
      c.conn
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("dpop", proof(c))
      |> post(path, body)

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp proof(c, path \\ "/oauth/token") do
    {_, public} = JOSE.JWK.to_public_map(c.key)

    JOSE.JWT.sign(c.key, %{"alg" => "ES256", "typ" => "dpop+jwt", "jwk" => public}, %{
      "jti" => random(),
      "iat" => System.system_time(:second),
      "nonce" => c.nonce,
      "htm" => "POST",
      "htu" => AtollWeb.Endpoint.url() <> path
    })
    |> JOSE.JWS.compact()
    |> elem(1)
  end
end
