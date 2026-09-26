defmodule AtollWeb.HandleUpdateControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Repo, Repositories, SigningKey, Multikey, KeyVault}
  alias Atoll.Accounts.{Profile, Sessions, AppPasswords}
  alias Atoll.Identity.PLC.{Operation, Registration, Registrations, Update}
  alias Atoll.Identity.HandleReservation
  import Ecto.Query
  @path "/xrpc/com.atproto.identity.updateHandle"

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

    %{did: genesis.did, pair: pair, state: state}
  end

  test "HTTP update signs, publishes and completes once; repeated requests are no-ops", ctx do
    directory(ctx)
    assert response(request(ctx, %{"handle" => "BOB.example.com"}), 200) == ""
    assert Repo.get!(Profile, ctx.did).handle == "bob.example.com"
    assert Repo.aggregate(HandleReservation, :count) == 0
    assert response(request(ctx, %{"handle" => "bob.example.com"}), 200) == ""
    assert length(Agent.get(ctx.state, & &1.posts)) == 1

    assert Repo.aggregate(from(e in Atoll.Repositories.Event, where: e.kind == :identity), :count) ==
             1

    conn = %{build_conn() | host: "bob.example.com"} |> get("/.well-known/atproto-did")
    assert response(conn, 200) == ctx.did

    assert %{build_conn() | host: "alice.example.com"}
           |> get("/.well-known/atproto-did")
           |> response(404)
  end

  test "ambiguous submission retains the old handle and retries use the exact persisted operation",
       ctx do
    Agent.update(ctx.state, &%{&1 | ambiguous: true})
    directory(ctx)
    assert request(ctx, %{"handle" => "bob.example.com"}) |> json_response(503)
    row = Repo.one!(Update)
    assert is_nil(row.confirmed_at)
    assert Repo.get!(Profile, ctx.did).handle == "alice.example.com"
    assert Repo.get!(HandleReservation, "bob.example.com").cid == row.cid
    assert request(ctx, %{"handle" => "charlie.example.com"}) |> json_response(409)
    assert request(ctx, %{"handle" => "bob.example.com"}) |> response(200) == ""
    assert Agent.get(ctx.state, & &1.posts) == [row.operation]
    assert Repo.get_by!(Update, did: ctx.did, cid: row.cid).completed_at
  end

  test "full-session authorization, method, body limits and input validation precede identity mutation",
       ctx do
    assert build_conn()
           |> put_req_header("content-type", "application/json")
           |> post(@path, Jason.encode!(%{"handle" => "bob.example.com"}))
           |> json_response(401)

    {:ok, app} = AppPasswords.create(ctx.pair.access_jwt, %{"name" => "handle app"})
    {:ok, pair} = Sessions.create(ctx.did, app.password)
    assert request(%{ctx | pair: pair}, %{"handle" => "bob.example.com"}) |> json_response(403)
    assert build_conn() |> get(@path) |> json_response(405)
    assert request(ctx, %{"handle" => "bad"}) |> json_response(400)
    assert request(ctx, %{"handle" => "bob.example.com", "did" => ctx.did}) |> json_response(400)
    assert request(ctx, %{"handle" => String.duplicate("x", 5000)}) |> json_response(413)
    assert Repo.aggregate(Update, :count) == 0
  end

  test "missing rotation key and foreign custom-domain claims fail without submission", ctx do
    directory(ctx)
    Repo.delete_all(Registration)
    assert request(ctx, %{"handle" => "bob.example.com"}) |> json_response(503)

    Application.put_env(:atoll, :identity_resolution_options,
      txt_lookup: fn _ -> [["did=did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"]] end
    )

    assert request(ctx, %{"handle" => "custom.other.com"}) |> json_response(400)
    assert Agent.get(ctx.state, & &1.posts) == []
    assert Repo.aggregate(Update, :count) == 0
  end

  test "custom handle update requires ownership and becomes the account handle", ctx do
    directory(ctx)

    Application.put_env(:atoll, :identity_resolution_options,
      txt_lookup: fn _ -> [["did=" <> ctx.did]] end
    )

    assert request(ctx, %{"handle" => "custom.other.com"}) |> response(200) == ""
    assert Repo.get!(Profile, ctx.did).handle == "custom.other.com"
    assert length(Agent.get(ctx.state, & &1.posts)) == 1
  end

  defp request(ctx, body) do
    id = rem(System.unique_integer([:positive]), 65_536)

    %{build_conn() | remote_ip: {10, 82, div(id, 256), rem(id, 256)}}
    |> put_req_header("authorization", "Bearer " <> ctx.pair.access_jwt)
    |> put_req_header("content-type", "application/json")
    |> post(@path, Jason.encode!(body))
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
