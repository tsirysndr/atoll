defmodule AtollWeb.AdminEmailControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Repo, Repositories, SigningKey}

  alias Atoll.Accounts.{
    AdminEmail,
    Credentials,
    Deletion,
    EmailConfirmation,
    PasswordReset,
    Profile,
    Sessions
  }

  alias Atoll.Moderation.Audit
  @path "/xrpc/com.atproto.admin.updateAccountEmail"
  @did "did:web:admin-email.example.com"
  @secret "operator-email-test-secret-at-least-32"
  @password "account email test password"
  @challenge_fields [
    :email_confirmation_digest,
    :email_confirmation_expires_at,
    :email_confirmation_requested_at,
    :email_update_digest,
    :email_update_expires_at,
    :email_update_requested_at,
    :password_reset_digest,
    :password_reset_expires_at,
    :password_reset_requested_at,
    :auth_factor_digest,
    :auth_factor_expires_at,
    :auth_factor_requested_at,
    :deletion_digest,
    :deletion_expires_at,
    :deletion_requested_at
  ]

  setup %{conn: conn} do
    previous =
      Map.new(
        [:admin_password, :session_signing_key, :email_worker, :email_delivery_options],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    Application.put_env(:atoll, :admin_password, @secret)
    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))

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
      handle: "admin-email.example.com",
      email: "old@example.com",
      email_confirmed_at: DateTime.utc_now()
    })

    {:ok, _} = Credentials.create(@did, @password)
    {:ok, pair} = Sessions.create(@did, @password)
    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 65, div(id, 256), rem(id, 256)}}, pair: pair}
  end

  test "changes normalized email, clears every challenge and factor, and audits atomically", c do
    seed_challenges()
    before = Repo.get!(Profile, @did)
    seq = Atoll.Repositories.Events.latest_seq()

    result =
      auth(c.conn) |> post(@path, %{account: "ADMIN-EMAIL.EXAMPLE.COM", email: "New@Example.COM"})

    assert response(result, 200) == ""
    assert get_resp_header(result, "cache-control") == ["no-store"]
    profile = Repo.get!(Profile, @did)
    assert profile.email == "new@example.com"
    assert is_nil(profile.email_confirmed_at)
    refute profile.email_auth_factor
    for field <- @challenge_fields, do: assert(is_nil(Map.fetch!(profile, field)))
    assert {:ok, %{entries: [entry]}} = Audit.list()
    assert entry.operation == "com.atproto.admin.updateAccountEmail"

    assert entry.before == %{
             "email" => "old@example.com",
             "emailAuthFactor" => true,
             "emailConfirmedAt" => DateTime.to_iso8601(before.email_confirmed_at)
           }

    assert entry.after == %{
             "email" => "new@example.com",
             "emailAuthFactor" => false,
             "emailConfirmedAt" => nil
           }

    assert entry.requested == %{
             "account" => "ADMIN-EMAIL.EXAMPLE.COM",
             "email" => "new@example.com"
           }

    assert Atoll.Repositories.Events.latest_seq() == seq
    assert {:ok, _} = Sessions.authenticate(c.pair.access_jwt)
    assert {:ok, _} = Sessions.create_email("new@example.com", @password)
    assert {:error, _} = Sessions.create_email("old@example.com", @password)
  end

  test "same normalized address preserves confirmation, factor and outstanding challenges" do
    seed_challenges()
    before = Repo.get!(Profile, @did)

    assert {:ok, :unchanged} =
             AdminEmail.update(%{"account" => @did, "email" => "OLD@example.com"})

    assert Repo.get!(Profile, @did) == before
    assert {:ok, %{entries: [entry]}} = Audit.list()
    assert entry.before == entry.after
  end

  test "old real recovery and deletion codes fail; new confirmations use the Worker", c do
    expect_code("old@example.com")
    assert {:ok, :requested} = PasswordReset.request(%{"email" => "old@example.com"})
    assert_receive {:code, reset_code}
    expect_code("old@example.com")
    assert {:ok, :sent} = Deletion.request(c.pair.access_jwt)
    assert_receive {:code, deletion_code}
    {:ok, app} = Atoll.Accounts.AppPasswords.create(c.pair.access_jwt, %{"name" => "preserved"})
    assert {:ok, :updated} = AdminEmail.update(%{"account" => @did, "email" => "new@example.com"})

    assert {:error, _} =
             PasswordReset.reset(%{"token" => reset_code, "password" => "replacement password"})

    assert {:error, _} =
             Deletion.delete(%{"did" => @did, "password" => @password, "token" => deletion_code})

    assert {:ok, _} = Sessions.create(@did, app.password)
    expect_code("new@example.com")
    assert {:ok, :sent} = EmailConfirmation.request(c.pair.access_jwt)
    assert_receive {:code, confirmation_code}

    assert {:ok, _} =
             EmailConfirmation.confirm(c.pair.access_jwt, %{
               "email" => "new@example.com",
               "token" => confirmation_code
             })

    assert Repo.get!(Profile, @did).email_confirmed_at
  end

  test "failures and outer rollbacks leave both profile and history unchanged", c do
    other = "did:web:occupied.example.com"
    {:ok, _} = Repositories.create(other, SigningKey.generate())

    Repo.insert!(%Profile{
      did: other,
      handle: "occupied.example.com",
      email: "occupied@example.com"
    })

    before = Repo.get!(Profile, @did)

    for params <- [
          %{account: @did, email: "occupied@example.com"},
          %{account: @did, email: "invalid"},
          %{account: "did:web:missing.example.com", email: "valid@example.com"},
          %{account: @did, email: "valid@example.com", extra: true},
          %{email: "valid@example.com"}
        ] do
      assert auth(c.conn) |> post(@path, params) |> json_response(400)
    end

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, :updated} =
                        AdminEmail.update(%{"account" => @did, "email" => "valid@example.com"})

               Repo.rollback(:cancelled)
             end)

    assert Repo.get!(Profile, @did) == before
    assert {:ok, %{entries: []}} = Audit.list()
  end

  test "all account statuses stay unchanged and endpoint requires operator auth before JSON", c do
    assert c.conn
           |> put_req_header("content-type", "application/json")
           |> post(@path, "{")
           |> json_response(401)

    assert c.conn
           |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
           |> post(@path, %{account: @did, email: "new@example.com"})
           |> json_response(401)

    assert auth(c.conn) |> get(@path) |> json_response(405)

    for status <- [:deactivated, :suspended, :takendown] do
      {:ok, _} = Repositories.set_status(@did, status)

      assert response(
               auth(c.conn) |> post(@path, %{account: @did, email: "#{status}@example.com"}),
               200
             ) == ""

      assert Repo.get!(Atoll.Repositories.Head, @did).status == status
    end
  end

  defp seed_challenges do
    now = System.system_time(:second)

    changes =
      Enum.map(@challenge_fields, fn field ->
        value =
          cond do
            String.ends_with?(Atom.to_string(field), "digest") -> :binary.copy(<<7>>, 32)
            String.ends_with?(Atom.to_string(field), "expires_at") -> now + 900
            true -> now
          end

        {field, value}
      end)

    Repo.get!(Profile, @did)
    |> Ecto.Changeset.change([{:email_auth_factor, true} | changes])
    |> Repo.update!()
  end

  defp expect_code(email) do
    parent = self()

    Req.Test.expect(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer secret"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      message = Jason.decode!(body)
      assert message["to"] == email
      [_, code] = Regex.run(~r/code is: ([A-Za-z0-9_-]{32})/, message["text"])
      send(parent, {:code, code})
      Plug.Conn.send_resp(conn, 202, "")
    end)
  end

  defp auth(conn),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Basic " <> Base.encode64("admin:" <> @secret))
end
