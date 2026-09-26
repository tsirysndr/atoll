defmodule AtollWeb.PLCSubmissionControllerTest do
  use AtollWeb.ConnCase, async: false
  import Ecto.Query
  alias Atoll.{Repo, Repositories, SigningKey, Multikey, KeyVault}
  alias Atoll.Accounts.{Profile, Sessions, AppPasswords}
  alias Atoll.Identity.PLC.{Operation, Update}
  @path "/xrpc/com.atproto.identity.submitPlcOperation"

  setup do
    keys = [
      :session_signing_key,
      :key_encryption_key,
      :pds,
      :plc_submission_options,
      :identity_resolution_options
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

    source = SigningKey.generate()
    local = SigningKey.generate()
    rotation = SigningKey.generate()
    {:ok, source_id} = Multikey.to_did_key(source.curve, source.public)
    {:ok, local_id} = Multikey.to_did_key(local.curve, local.public)
    {:ok, rotating} = Multikey.to_did_key(rotation.curve, rotation.public)

    {:ok, genesis} =
      Operation.create_atproto(
        source_id,
        "alice.example.com",
        "https://source.example.com",
        [rotating],
        rotation
      )

    {:ok, _} = Repositories.create(genesis.did, local)
    {:ok, _} = Repositories.set_status(genesis.did, :deactivated)
    Repo.insert!(%Profile{did: genesis.did, handle: "alice.example.com"})
    {:ok, _} = KeyVault.store(genesis.did, local)
    {:ok, pair} = Sessions.create_for_account(genesis.did)
    {:ok, unsigned} = Operation.successor(genesis.operation)

    unsigned =
      unsigned
      |> Map.put("verificationMethods", %{"atproto" => local_id})
      |> Map.put("services", %{
        "atproto_pds" => %{
          "type" => "AtprotoPersonalDataServer",
          "endpoint" => AtollWeb.Endpoint.url()
        }
      })

    {:ok, operation} = Operation.sign(unsigned, rotation)

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

    %{did: genesis.did, pair: pair, state: state, operation: operation, rotation: rotation}
  end

  test "migration submission uses the destination key and completes once without activating",
       ctx do
    directory(ctx)
    before = Repo.get!(Atoll.Repositories.Head, ctx.did)
    for _ <- 1..2, do: assert(request(ctx, ctx.operation) |> response(200) == "")
    assert Agent.get(ctx.state, & &1.posts) == [ctx.operation]
    assert Repo.one!(Update).completed_at
    assert Repo.get!(Atoll.Repositories.Head, ctx.did) == before
    assert before.status == :deactivated
    assert Repo.get!(Atoll.Identity.Observation, ctx.did).handle == "alice.example.com"

    assert Repo.aggregate(from(e in Atoll.Repositories.Event, where: e.kind == :identity), :count) ==
             1
  end

  test "ambiguous submission retries the persisted operation without another POST", ctx do
    Agent.update(ctx.state, &%{&1 | ambiguous: true})
    directory(ctx)
    assert request(ctx, ctx.operation) |> json_response(503)
    refute Repo.one!(Update).confirmed_at
    assert request(ctx, ctx.operation) |> response(200) == ""
    assert Agent.get(ctx.state, & &1.posts) == [ctx.operation]
    assert Repo.one!(Update).completed_at
  end

  test "already accepted operations can be journaled from their verified surviving predecessor",
       ctx do
    {:ok, cid} = Operation.cid(ctx.operation)

    Agent.update(ctx.state, fn state ->
      %{
        state
        | audit:
            state.audit ++
              [
                %{
                  "did" => ctx.did,
                  "cid" => cid,
                  "operation" => ctx.operation,
                  "nullified" => false,
                  "createdAt" => "2026-01-02T00:00:00Z"
                }
              ]
      }
    end)

    directory(ctx)
    assert request(ctx, ctx.operation) |> response(200) == ""
    assert Agent.get(ctx.state, & &1.posts) == []
    assert Repo.one!(Update).completed_at
  end

  test "incompatible service, handle, and signing key cannot be submitted", ctx do
    for unsigned <- [
          ctx.operation
          |> Map.delete("sig")
          |> Map.put("alsoKnownAs", ["at://other.example.com"]),
          ctx.operation |> Map.delete("sig") |> Map.put("verificationMethods", %{}),
          ctx.operation |> Map.delete("sig") |> Map.put("services", %{})
        ] do
      {:ok, op} = Operation.sign(unsigned, ctx.rotation)
      assert request(ctx, op) |> json_response(400)
    end

    assert Repo.aggregate(Update, :count) == 0
  end

  test "full session, method, and input limits protect submission", ctx do
    {:ok, app} = AppPasswords.create(ctx.pair.access_jwt, %{"name" => "submit app"})
    {:ok, pair} = Sessions.create(ctx.did, app.password)
    assert request(%{ctx | pair: pair}, ctx.operation) |> json_response(403)
    assert build_conn() |> get(@path) |> json_response(405)
    assert request(ctx, String.duplicate("x", 17000)) |> json_response(413)
    assert Repo.aggregate(Update, :count) == 0
  end

  test "invalid signatures and empty rotation authority never reach directory submission", ctx do
    assert request(ctx, Map.put(ctx.operation, "sig", "bad")) |> json_response(400)
    unsigned = ctx.operation |> Map.delete("sig") |> Map.put("rotationKeys", [])
    {:ok, sig} = SigningKey.sign(ctx.rotation, Atoll.CBOR.encode!(unsigned))
    invalid = Map.put(unsigned, "sig", Base.url_encode64(sig, padding: false))
    assert request(ctx, invalid) |> json_response(400)
    directory(ctx)
    {:ok, foreign} = Operation.sign(Map.delete(ctx.operation, "sig"), SigningKey.generate())
    assert request(ctx, foreign) |> json_response(400)
    assert Agent.get(ctx.state, & &1.posts) == []
    assert Repo.aggregate(Update, :count) == 0
  end

  test "session revocation during evidence lookup cannot stage or submit an operation", ctx do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET"
      audit = Agent.get(ctx.state, & &1.audit)

      if String.ends_with?(conn.request_path, "/log/audit") do
        {:ok, :ok} = Sessions.revoke(ctx.pair.refresh_jwt)
        Req.Test.json(conn, audit)
      else
        Req.Test.json(conn, List.last(audit)["operation"])
      end
    end)

    assert request(ctx, ctx.operation) |> json_response(401)
    assert Repo.aggregate(Update, :count) == 0
  end

  defp request(ctx, operation) do
    id = rem(System.unique_integer([:positive]), 65_536)

    %{build_conn() | remote_ip: {10, 85, div(id, 256), rem(id, 256)}}
    |> put_req_header("authorization", "Bearer " <> ctx.pair.access_jwt)
    |> put_req_header("content-type", "application/json")
    |> post(@path, Jason.encode!(%{"operation" => operation}))
  end

  defp directory(ctx) do
    Req.Test.stub(__MODULE__, fn conn ->
      assert URI.decode(conn.request_path) |> String.starts_with?("/" <> ctx.did)

      cond do
        conn.method == "POST" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          op = Jason.decode!(body)
          audit = Agent.get(ctx.state, & &1.audit)
          assert {:ok, _} = Operation.verify_update(List.last(audit)["operation"], op)
          {:ok, cid} = Operation.cid(op)

          entry = %{
            "did" => ctx.did,
            "cid" => cid,
            "operation" => op,
            "nullified" => false,
            "createdAt" => "2026-01-02T00:00:00Z"
          }

          ambiguous =
            Agent.get_and_update(ctx.state, fn state ->
              {state.ambiguous,
               %{
                 state
                 | audit: state.audit ++ [entry],
                   posts: state.posts ++ [op],
                   fail_read: state.ambiguous,
                   ambiguous: false
               }}
            end)

          if ambiguous,
            do: Req.Test.transport_error(conn, :timeout),
            else: Plug.Conn.send_resp(conn, 200, "")

        true ->
          state =
            Agent.get_and_update(ctx.state, fn state -> {state, %{state | fail_read: false}} end)

          cond do
            state.fail_read ->
              Req.Test.transport_error(conn, :timeout)

            String.ends_with?(conn.request_path, "/log/audit") ->
              Req.Test.json(conn, state.audit)

            String.ends_with?(conn.request_path, "/log/last") ->
              Req.Test.json(conn, List.last(state.audit)["operation"])
          end
      end
    end)
  end
end
