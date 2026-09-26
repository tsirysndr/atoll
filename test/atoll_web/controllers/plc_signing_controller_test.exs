defmodule AtollWeb.PLCSigningControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Repo, Repositories, SigningKey, Multikey, KeyVault}
  alias Atoll.Accounts.{Profile, Sessions, AppPasswords}
  alias Atoll.Identity.PLC.{Operation, Registration, Registrations, Update}
  @path "/xrpc/com.atproto.identity.signPlcOperation"

  setup do
    keys = [
      :session_signing_key,
      :key_encryption_key,
      :pds,
      :plc_submission_options,
      :identity_resolution_options,
      :email_worker,
      :email_delivery_options
    ]

    prior = Map.new(keys, &{&1, Application.fetch_env(:atoll, &1)})
    endpoint = Application.fetch_env!(:atoll, AtollWeb.Endpoint)

    AtollWeb.Endpoint.config_change(
      [
        {AtollWeb.Endpoint,
         Keyword.put(endpoint, :url, scheme: "https", host: "pds.example.com", port: 443)}
      ],
      []
    )

    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))

    Application.put_env(:atoll, :pds,
      did: "did:web:pds.example.com",
      available_user_domains: [".example.com"]
    )

    Application.put_env(:atoll, :plc_submission_options, plug: {Req.Test, __MODULE__})
    Application.put_env(:atoll, :identity_resolution_options, [])

    on_exit(fn ->
      AtollWeb.Endpoint.config_change([{AtollWeb.Endpoint, endpoint}], [])

      for {key, value} <- prior do
        case value do
          {:ok, val} -> Application.put_env(:atoll, key, val)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    key = SigningKey.generate()
    rotation = SigningKey.generate()
    {:ok, signing} = Multikey.to_did_key(key.curve, key.public)
    {:ok, rotating} = Multikey.to_did_key(rotation.curve, rotation.public)

    {:ok, genesis} =
      Operation.create_atproto(
        signing,
        "alice.example.com",
        AtollWeb.Endpoint.url(),
        [rotating],
        rotation
      )

    {:ok, _} = Repositories.create(genesis.did, key)
    {:ok, _} = Repositories.set_status(genesis.did, :deactivated)
    Repo.insert!(%Profile{did: genesis.did, handle: "alice.example.com"})
    {:ok, _} = KeyVault.store(genesis.did, key)
    {:ok, _} = Registrations.stage(genesis.did, genesis.operation, rotation)

    Repo.update_all(Registration,
      set: [confirmed_at: DateTime.utc_now(), completed_at: DateTime.utc_now()]
    )

    {:ok, _} = Repositories.set_status(genesis.did, :active)
    {:ok, pair} = Sessions.create_for_account(genesis.did)

    entry = %{
      "did" => genesis.did,
      "cid" => genesis.cid,
      "operation" => genesis.operation,
      "nullified" => false,
      "createdAt" => "2026-01-01T00:00:00Z"
    }

    state =
      start_supervised!(
        {Agent, fn -> %{audit: [entry], posts: [], ambiguous: false, fail_read: false} end}
      )

    Repo.get!(Profile, genesis.did)
    |> Ecto.Changeset.change(email: "owner@example.com", email_confirmed_at: DateTime.utc_now())
    |> Repo.update!()

    caller = self()

    Application.put_env(:atoll, :email_worker,
      url: "https://worker.example.com/send",
      token: "secret"
    )

    Application.put_env(:atoll, :email_delivery_options,
      plug: fn conn ->
        assert conn.host == "worker.example.com"
        {:ok, bytes, conn} = Plug.Conn.read_body(conn)
        message = Jason.decode!(bytes)
        [_, code] = Regex.run(~r/signing code is: ([A-Za-z0-9_-]{32})/, message["text"])
        send(caller, {:signing_code, code})
        Plug.Conn.send_resp(conn, 202, "")
      end
    )

    %{did: genesis.did, pair: pair, state: state, previous: genesis.operation}
  end

  test "email-authorized signing returns a valid migration operation without publishing or changing local state",
       ctx do
    code = code(ctx)
    directory(ctx)
    new_key = SigningKey.generate()
    {:ok, new_key_id} = Multikey.to_did_key(new_key.curve, new_key.public)

    service = %{
      "atproto_pds" => %{
        "type" => "AtprotoPersonalDataServer",
        "endpoint" => "https://destination.example.com"
      }
    }

    input = %{
      "token" => code,
      "rotationKeys" => [new_key_id],
      "verificationMethods" => %{"atproto" => new_key_id},
      "services" => service,
      "alsoKnownAs" => ["at://elsewhere.example.com"]
    }

    op = request(ctx, input) |> json_response(200) |> Map.fetch!("operation")
    assert {:ok, _} = Operation.verify_update(ctx.previous, op)
    assert op["rotationKeys"] == [new_key_id]
    assert op["services"] == service
    assert op["verificationMethods"] == %{"atproto" => new_key_id}
    assert Repo.get!(Profile, ctx.did).handle == "alice.example.com"
    assert is_nil(Repo.get!(Profile, ctx.did).plc_signature_digest)
    assert Repo.aggregate(Update, :count) == 0
    assert request(ctx, input) |> json_response(400) |> Map.fetch!("error") == "InvalidToken"
  end

  test "invalid operation rolls back token consumption; a deactivated owner can retry for migration",
       ctx do
    code = code(ctx)
    directory(ctx)
    assert request(ctx, %{"token" => code, "rotationKeys" => []}) |> json_response(400)
    assert Repo.get!(Profile, ctx.did).plc_signature_digest
    assert request(ctx, %{"token" => code, "prev" => "forged"}) |> json_response(400)
    {:ok, _} = Repositories.set_status(ctx.did, :deactivated)
    op = request(ctx, %{"token" => code}) |> json_response(200) |> Map.fetch!("operation")
    assert {:ok, _} = Operation.verify_update(ctx.previous, op)
    assert op["services"] == ctx.previous["services"]
  end

  test "full session and code are required before directory access and JSON is bounded", ctx do
    assert request(ctx, %{}) |> json_response(400) |> Map.fetch!("error") == "TokenRequired"
    assert request(ctx, %{"token" => String.duplicate("x", 32)}) |> json_response(400)
    code = code(ctx)
    {:ok, app} = AppPasswords.create(ctx.pair.access_jwt, %{"name" => "signing app"})
    {:ok, pair} = Sessions.create(ctx.did, app.password)
    assert request(%{ctx | pair: pair}, %{"token" => code}) |> json_response(403)

    assert request(ctx, %{"token" => code, "alsoKnownAs" => [String.duplicate("x", 17000)]})
           |> json_response(413)

    assert build_conn() |> get(@path) |> json_response(405)
    assert Repo.get!(Profile, ctx.did).plc_signature_digest
  end

  test "pending journal operations block conflicting signatures without consuming authorization",
       ctx do
    code = code(ctx)
    directory(ctx)
    {:ok, next} = Operation.successor(ctx.previous)
    {:ok, rotation} = Registrations.rotation_key(ctx.did)
    {:ok, op} = Operation.sign(next, rotation)
    audit = Agent.get(ctx.state, & &1.audit)
    {:ok, _} = Atoll.Identity.PLC.Updates.stage(ctx.did, audit, op)
    assert request(ctx, %{"token" => code}) |> json_response(409)
    assert Repo.get!(Profile, ctx.did).plc_signature_digest
  end

  test "operation size limits apply inside the larger JSON envelope", ctx do
    code = code(ctx)
    directory(ctx)

    assert request(ctx, %{
             "token" => code,
             "alsoKnownAs" => ["https://example.com/" <> String.duplicate("x", 7600)]
           })
           |> json_response(400)

    assert Repo.get!(Profile, ctx.did).plc_signature_digest

    op =
      request(ctx, %{
        "token" => code,
        "alsoKnownAs" => ["https://example.com/" <> String.duplicate("x", 4500)]
      })
      |> json_response(200)
      |> Map.fetch!("operation")

    assert {:ok, _} = Operation.verify_update(ctx.previous, op)
  end

  test "revocation during directory lookup prevents signing and preserves the code", ctx do
    code = code(ctx)

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET"

      if String.ends_with?(conn.request_path, "/log/audit") do
        {:ok, :ok} = Sessions.revoke(ctx.pair.refresh_jwt)
        Req.Test.json(conn, Agent.get(ctx.state, & &1.audit))
      else
        Req.Test.json(conn, ctx.previous)
      end
    end)

    assert request(ctx, %{"token" => code}) |> json_response(401)
    assert Repo.get!(Profile, ctx.did).plc_signature_digest
  end

  defp directory(ctx) do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET"
      audit = Agent.get(ctx.state, & &1.audit)

      if String.ends_with?(conn.request_path, "/log/audit"),
        do: Req.Test.json(conn, audit),
        else: Req.Test.json(conn, ctx.previous)
    end)
  end

  defp code(ctx) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> ctx.pair.access_jwt)
      |> post("/xrpc/com.atproto.identity.requestPlcOperationSignature")

    assert response(conn, 200) == ""
    assert_receive {:signing_code, code}
    code
  end

  defp request(ctx, body) do
    id = rem(System.unique_integer([:positive]), 65_536)

    %{build_conn() | remote_ip: {10, 84, div(id, 256), rem(id, 256)}}
    |> put_req_header("authorization", "Bearer " <> ctx.pair.access_jwt)
    |> put_req_header("content-type", "application/json")
    |> post(@path, Jason.encode!(body))
  end
end
