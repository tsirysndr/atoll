defmodule AtollWeb.EmailUpdateControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.Accounts.{Credentials, Profile, Sessions}
  alias Atoll.{Repo, Repositories, SigningKey}
  @did "did:web:update-email.example.com"
  @request "/xrpc/com.atproto.server.requestEmailUpdate"
  @update "/xrpc/com.atproto.server.updateEmail"

  setup %{conn: conn} do
    previous =
      Map.new(
        [:session_signing_key, :email_worker, :email_delivery_options],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    Application.put_env(:atoll, :session_signing_key, :binary.copy(<<32>>, 32))

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

    {:ok, _} = Repositories.create(@did, SigningKey.generate())

    Repo.insert!(%Profile{
      did: @did,
      handle: "update-email.example.com",
      email: "old@example.com",
      email_confirmed_at: DateTime.utc_now()
    })

    {:ok, _} = Credentials.create(@did, "email update password")
    {:ok, pair} = Sessions.create(@did, "email update password")
    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 46, div(id, 256), rem(id, 256)}}, pair: pair}
  end

  test "confirmed address requires a code sent to the old address and loses confirmation on change",
       c do
    assert json_response(update(c, %{email: "new@example.com"}), 400)["error"] == "TokenRequired"
    code = request_code(c)

    assert json_response(
             update(c, %{email: "new@example.com", token: String.duplicate("x", 32)}),
             400
           )["error"] == "InvalidToken"

    assert response(update(c, %{email: "NEW@example.com", token: code}), 200) == ""

    assert %Profile{
             email: "new@example.com",
             email_confirmed_at: nil,
             email_update_digest: nil,
             email_confirmation_digest: nil
           } = Repo.get!(Profile, @did)

    # A consumed token cannot authorize a subsequent change once ownership is confirmed again.
    change(email_confirmed_at: DateTime.utc_now())

    assert json_response(update(c, %{email: "another@example.com", token: code}), 400)["error"] ==
             "InvalidToken"
  end

  test "unconfirmed or absent email needs no token and no email is sent", c do
    for email <- ["old@example.com", nil] do
      change(email: email, email_confirmed_at: nil)
      assert json_response(request(c), 200) == %{"tokenRequired" => false}
      assert response(update(c, %{email: "new@example.com"}), 200) == ""
      assert Repo.get!(Profile, @did).email == "new@example.com"
    end
  end

  test "cooldown, expiry, replacement, and cross-purpose token isolation", c do
    code = request_code(c)
    assert json_response(request(c), 429)["error"] == "RateLimitExceeded"
    change(email_update_expires_at: System.system_time(:second) - 1)

    assert json_response(update(c, %{email: "new@example.com", token: code}), 400)["error"] ==
             "ExpiredToken"

    change(email_update_requested_at: System.system_time(:second) - 61)
    next = request_code(c)
    assert response(update(c, %{email: "new@example.com", token: code}), 400)

    assert {:error, :invalid_email_token} =
             Atoll.Accounts.EmailConfirmation.confirm(c.pair.access_jwt, %{
               "email" => "old@example.com",
               "token" => next
             })

    assert response(update(c, %{email: "new@example.com", token: next}), 200) == ""
  end

  test "duplicate address failure preserves authorization for a corrected retry", c do
    other = "did:web:occupied.example.com"
    {:ok, _} = Repositories.create(other, SigningKey.generate())

    Repo.insert!(%Profile{
      did: other,
      handle: "occupied.example.com",
      email: "occupied@example.com"
    })

    code = request_code(c)
    assert response(update(c, %{email: "occupied@example.com", token: code}), 400)
    assert Repo.get!(Profile, @did).email == "old@example.com"
    assert response(update(c, %{email: "available@example.com", token: code}), 200) == ""
  end

  test "email changes clear outstanding confirmation tokens and preserve cooldown", c do
    change(
      email_confirmed_at: nil,
      email_confirmation_digest: :crypto.hash(:sha256, "old token"),
      email_confirmation_expires_at: System.system_time(:second) + 900,
      email_confirmation_requested_at: System.system_time(:second)
    )

    assert response(update(c, %{email: "new@example.com"}), 200) == ""
    profile = Repo.get!(Profile, @did)
    assert is_nil(profile.email_confirmation_digest)
    assert is_nil(profile.email_confirmation_expires_at)

    assert {:error, :email_rate_limited} =
             Atoll.Accounts.EmailConfirmation.request(c.pair.access_jwt)
  end

  test "malformed input, unsupported factors, missing auth and wrong methods fail", c do
    assert response(post(c.conn, @request), 401)
    assert response(c.conn |> auth(c) |> get(@request), 405)
    assert response(c.conn |> auth(c) |> get(@update), 405)

    for params <- [
          %{},
          %{email: "a..b@example.com"},
          %{email: "bad"},
          %{email: "new@example.com", emailAuthFactor: true},
          %{email: "new@example.com", extra: true}
        ] do
      assert response(update(c, params), 400)
    end

    assert response(
             c.conn
             |> auth(c)
             |> put_req_header("content-type", "application/json")
             |> post(@update, String.duplicate("x", 4097)),
             413
           )

    {:ok, _} = Repositories.set_status(@did, :suspended)
    assert response(request(c), 400)
  end

  test "Worker failure cannot change the address", c do
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 503, "private"))
    assert response(request(c), 503)
    assert Repo.get!(Profile, @did).email == "old@example.com"
    assert response(request(c), 429)
  end

  defp request_code(c) do
    parent = self()

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      message = Jason.decode!(body)
      assert message["to"] == "old@example.com"
      [_, code] = Regex.run(~r/code is: ([A-Za-z0-9_-]{32})/, message["text"])
      send(parent, {:code, code})
      Plug.Conn.send_resp(conn, 202, "")
    end)

    assert json_response(request(c), 200) == %{"tokenRequired" => true}
    assert_receive {:code, code}
    code
  end

  defp request(c), do: c.conn |> auth(c) |> post(@request)

  defp change(attrs),
    do: Repo.get!(Profile, @did) |> Ecto.Changeset.change(attrs) |> Repo.update!()

  defp auth(conn, c), do: put_req_header(conn, "authorization", "Bearer " <> c.pair.access_jwt)

  defp update(c, params),
    do:
      c.conn
      |> auth(c)
      |> put_req_header("content-type", "application/json")
      |> post(@update, Jason.encode!(params))
end
