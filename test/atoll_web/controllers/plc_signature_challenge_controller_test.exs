defmodule AtollWeb.PLCSignatureChallengeControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Repo, Repositories, SigningKey}
  alias Atoll.Accounts.{Profile, Sessions, AppPasswords}
  alias Atoll.Identity.PLC.SignatureChallenges
  @did "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
  @path "/xrpc/com.atproto.identity.requestPlcOperationSignature"

  setup do
    keys = [:session_signing_key, :email_worker, :email_delivery_options]
    previous = Map.new(keys, &{&1, Application.fetch_env(:atoll, &1)})
    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))

    Application.put_env(:atoll, :email_worker,
      url: "https://worker.example.com/send",
      token: "worker-secret"
    )

    Application.put_env(:atoll, :email_delivery_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, val} -> Application.put_env(:atoll, key, val)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    {:ok, _} = Repositories.create(@did, SigningKey.generate())

    Repo.insert!(%Profile{
      did: @did,
      handle: "owner.example.com",
      email: "owner@example.com",
      email_confirmed_at: DateTime.utc_now()
    })

    {:ok, pair} = Sessions.create_for_account(@did)
    %{pair: pair}
  end

  test "Worker delivery stores only a digest and consumption is single-use and transactional",
       ctx do
    code = code(ctx)
    profile = Repo.get!(Profile, @did)
    assert byte_size(profile.plc_signature_digest) == 32
    refute profile.plc_signature_digest == code
    refute inspect(profile) =~ "plc_signature_digest:"

    assert {:error, :failed_signing} =
             Repo.transaction(fn ->
               assert @did == SignatureChallenges.consume!(ctx.pair.access_jwt, code)
               Repo.rollback(:failed_signing)
             end)

    assert {:ok, @did} = consume(ctx, code)
    assert {:error, :invalid_email_token} = consume(ctx, code)
    assert_raise ArgumentError, fn -> SignatureChallenges.consume!(ctx.pair.access_jwt, code) end
  end

  test "cooldown, expiry, address binding and replacement are enforced", ctx do
    first = code(ctx)
    assert request(ctx) |> json_response(429)
    profile = Repo.get!(Profile, @did)
    profile |> Ecto.Changeset.change(plc_signature_expires_at: 0) |> Repo.update!()
    assert {:error, :expired_email_token} = consume(ctx, first)

    Repo.get!(Profile, @did)
    |> Ecto.Changeset.change(plc_signature_requested_at: 0)
    |> Repo.update!()

    second = code(ctx)
    assert second != first
    assert {:error, :invalid_email_token} = consume(ctx, first)

    Repo.get!(Profile, @did)
    |> Ecto.Changeset.change(email: "changed@example.com")
    |> Repo.update!()

    assert {:error, :invalid_email_token} = consume(ctx, second)
  end

  test "requires full session and confirmed email and rejects bodies or wrong methods", ctx do
    assert build_conn() |> post(@path) |> json_response(401)
    {:ok, app} = AppPasswords.create(ctx.pair.access_jwt, %{"name" => "challenge test"})
    {:ok, pair} = Sessions.create(@did, app.password)
    assert request(%{ctx | pair: pair}) |> json_response(403)
    assert build_conn() |> get(@path) |> json_response(405)

    assert build_conn()
           |> put_req_header("content-type", "application/json")
           |> post(@path, "{}")
           |> json_response(400)

    Repo.get!(Profile, @did) |> Ecto.Changeset.change(email_confirmed_at: nil) |> Repo.update!()
    assert request(ctx) |> json_response(400)
    assert is_nil(Repo.get!(Profile, @did).plc_signature_digest)
  end

  test "Worker failure is reported without undoing cooldown or retrying automatically", ctx do
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 503, "unavailable"))
    assert request(ctx) |> json_response(503)
    assert Repo.get!(Profile, @did).plc_signature_digest
    assert request(ctx) |> json_response(429)
  end

  test "operator email correction invalidates tokens even if the original address is restored",
       ctx do
    code = code(ctx)

    assert {:ok, :updated} =
             Atoll.Accounts.AdminEmail.update(%{
               "account" => @did,
               "email" => "changed@example.com"
             })

    assert is_nil(Repo.get!(Profile, @did).plc_signature_digest)

    assert {:ok, :updated} =
             Atoll.Accounts.AdminEmail.update(%{
               "account" => @did,
               "email" => "owner@example.com"
             })

    Repo.get!(Profile, @did)
    |> Ecto.Changeset.change(email_confirmed_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:error, :invalid_email_token} = consume(ctx, code)
  end

  defp consume(ctx, code),
    do: Repo.transaction(fn -> SignatureChallenges.consume!(ctx.pair.access_jwt, code) end)

  defp request(ctx) do
    id = rem(System.unique_integer([:positive]), 65_536)

    %{build_conn() | remote_ip: {10, 83, div(id, 256), rem(id, 256)}}
    |> put_req_header("authorization", "Bearer " <> ctx.pair.access_jwt)
    |> post(@path)
  end

  defp code(ctx) do
    caller = self()

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "worker.example.com"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer worker-secret"]
      [id] = Plug.Conn.get_req_header(conn, "idempotency-key")
      assert byte_size(id) == 32
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      message = Jason.decode!(body)
      assert message["to"] == "owner@example.com"
      [_, code] = Regex.run(~r/signing code is: ([A-Za-z0-9_-]{32})/, message["text"])
      send(caller, {:code, code})
      Plug.Conn.send_resp(conn, 202, "")
    end)

    assert response(request(ctx), 200) == ""
    assert_receive {:code, code}
    code
  end
end
