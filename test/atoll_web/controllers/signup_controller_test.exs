defmodule AtollWeb.SignupControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Repo, KeyVault, Multikey, SigningKey}
  alias Atoll.Accounts.{Profile, Session, Sessions, Signup}
  alias Atoll.Identity.PLC.{Operation, Registration, Registrations}
  alias Atoll.Repositories.Head
  @path "/xrpc/com.atproto.server.createAccount"
  @params %{
    "handle" => "alice.users.example.com",
    "password" => "a long account password",
    "email" => "alice@example.com"
  }

  setup do
    id = rem(System.unique_integer([:positive]), 65_536)
    Process.put(:signup_test_ip, {10, 55, div(id, 256), rem(id, 256)})

    previous =
      Map.new(
        [
          :pds,
          :signup_enabled,
          :custom_domain_signup_enabled,
          :identity_resolution_options,
          :session_signing_key,
          :key_encryption_key,
          :plc_submission_options,
          :invite_code_required,
          :session_max_count
        ],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    endpoint = Application.fetch_env!(:atoll, AtollWeb.Endpoint)

    AtollWeb.Endpoint.config_change(
      [
        {AtollWeb.Endpoint,
         Keyword.put(endpoint, :url, scheme: "https", host: "pds.example.com", port: 443)}
      ],
      []
    )

    Application.put_env(:atoll, :pds,
      did: "did:web:pds.example.com",
      available_user_domains: [".users.example.com"]
    )

    Application.put_env(:atoll, :signup_enabled, true)
    Application.put_env(:atoll, :custom_domain_signup_enabled, false)
    Application.put_env(:atoll, :invite_code_required, false)
    Application.put_env(:atoll, :session_max_count, 100)
    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    Application.put_env(:atoll, :plc_submission_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      AtollWeb.Endpoint.config_change([{AtollWeb.Endpoint, endpoint}], [])

      for {name, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, name, value)
          :error -> Application.delete_env(:atoll, name)
        end
      end
    end)

    :ok
  end

  test "signup cleanup previews and deletes only expired unsubmitted reservations" do
    alias Atoll.Accounts.SignupCleanup
    old = cleanup_reservation("old", 8)
    recent = cleanup_reservation("recent", 0)
    assert {:ok, %{dids: [did], selected: 1, deleted: 0, dry_run: true}} = SignupCleanup.batch()
    assert did == old.did
    assert Repo.get!(Registration, old.did)
    seq = Atoll.Repositories.Events.latest_seq()
    assert {:ok, %{deleted: 1, more: false}} = SignupCleanup.batch(7, 100, false)
    refute Repo.get(Registration, old.did)
    refute Repo.get(Profile, old.did)
    refute Repo.get(Head, old.did)
    assert {:error, _} = KeyVault.fetch(old.did)
    assert Repo.get!(Registration, recent.did)
    assert {:ok, [%{kind: :account, did: ^did}]} = Atoll.Repositories.Events.list_after(seq)
    audits = Repo.all(Atoll.Moderation.AuditEntry)

    assert Enum.any?(
             audits,
             &(&1.operation == "atoll.accounts.cleanupSignups" and &1.did == old.did)
           )

    assert {:ok, %{deleted: 0}} = SignupCleanup.batch(7, 100, false)
  end

  test "submission marker protects cleanup before the first POST and survives ambiguous failure" do
    alias Atoll.Accounts.SignupCleanup
    old = cleanup_reservation("attempted", 8)
    original = Repo.get!(Registration, old.did)
    refute original.submission_started_at

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert Repo.get!(Registration, old.did).submission_started_at
      assert {:ok, %{deleted: 0}} = SignupCleanup.batch(7, 100, false)
      Req.Test.transport_error(conn, :timeout)
    end)

    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 404, ""))
    assert {:error, _} = Registrations.submit(old.did, plug: {Req.Test, __MODULE__})
    attempted = Repo.get!(Registration, old.did)
    assert attempted.submission_started_at
    refute attempted.confirmed_at
    assert {:ok, %{selected: 0}} = SignupCleanup.batch()
    accept_registration(original.operation)
    assert {:ok, _} = Registrations.submit(old.did, plug: {Req.Test, __MODULE__})

    assert Repo.get!(Registration, old.did).submission_started_at ==
             attempted.submission_started_at
  end

  test "cleanup skips confirmed and non-deactivated reservations even without a submission marker" do
    confirmed = cleanup_reservation("confirmed", 8)
    active = cleanup_reservation("active", 8)

    Repo.get!(Registration, confirmed.did)
    |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:ok, _} = Atoll.Repositories.set_status(active.did, :active)
    assert {:ok, %{selected: 0, deleted: 0}} = Atoll.Accounts.SignupCleanup.batch(7, 100, false)
    assert Repo.get!(Head, confirmed.did)
    assert Repo.get!(Head, active.did)
  end

  test "cleanup CLI defaults to preview and bounds each applied page" do
    cleanup_reservation("first", 8)
    cleanup_reservation("second", 8)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Accounts.CleanupSignups.run(["--limit", "1"])
      end)

    assert %{"dry_run" => true, "deleted" => 0, "more" => true} = Jason.decode!(output)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Accounts.CleanupSignups.run(["--limit", "1", "--apply"])
      end)

    assert %{"dry_run" => false, "deleted" => 1, "more" => true} = Jason.decode!(output)
    assert Repo.aggregate(Registration, :count) == 1

    for args <- [
          ["--limit", "0"],
          ["--older-than-days", "0"],
          ["--limit", "1", "--limit", "2"],
          ["--unknown"]
        ] do
      assert_raise Mix.Error, fn -> Mix.Tasks.Atoll.Accounts.CleanupSignups.run(args) end
    end
  end

  test "custom signup reservation is opt-in and createAccount cannot allocate it" do
    params = Map.put(@params, "handle", "alice.example.com")
    assert {:error, :unsupported_domain} = Signup.reserve_custom(params)
    Application.put_env(:atoll, :custom_domain_signup_enabled, true)
    assert json_response(request(params), 400)["error"] == "UnsupportedDomain"
    assert Repo.aggregate(Profile, :count) == 0
    assert {:ok, reservation} = Signup.reserve_custom(params)
    assert reservation.dns_name == "_atproto.alice.example.com"
    assert reservation.dns_value == "did=" <> reservation.did
    assert {:ok, ^reservation} = Signup.reserve_custom(params)
    assert Repo.aggregate(Atoll.Moderation.AuditEntry, :count) == 1
    assert Repo.aggregate(Registration, :count) == 1
    assert Repo.aggregate(Session, :count) == 0
    assert Repo.get!(Head, reservation.did).status == :deactivated

    assert {:error, :handle_not_available} =
             Signup.reserve_custom(Map.put(params, "password", "wrong password"))

    assert {:error, :signup_pending} = Sessions.create(reservation.did, params["password"])
    Application.put_env(:atoll, :signup_enabled, false)
    assert {:error, :signup_disabled} = Signup.reserve_custom(params)
  end

  test "custom signup verifies fresh forward claims before publication and activation" do
    Application.put_env(:atoll, :custom_domain_signup_enabled, true)
    params = Map.put(@params, "handle", "alice.example.com")
    {:ok, reservation} = Signup.reserve_custom(params)
    lookup = start_supervised!({Agent, fn -> {"did:web:wrong.example.com", 0} end})

    Application.put_env(:atoll, :identity_resolution_options,
      txt_lookup: fn name ->
        assert name == reservation.dns_name
        Agent.get_and_update(lookup, fn {did, count} -> {[["did=" <> did]], {did, count + 1}} end)
      end
    )

    assert json_response(request(params), 400)
    refute Repo.get!(Registration, reservation.did).confirmed_at
    Agent.update(lookup, fn _ -> {reservation.did, 0} end)
    original = Repo.get!(Registration, reservation.did)
    accept_registration(original.operation)
    result = json_response(request(params), 200)
    assert result["did"] == reservation.did
    assert {:ok, _} = Sessions.authenticate(result["accessJwt"])
    assert Agent.get(lookup, &elem(&1, 1)) == 2
    assert Repo.get!(Registration, reservation.did).operation == original.operation
  end

  test "custom claim lost during publication leaves confirmed signup pending for retry" do
    Application.put_env(:atoll, :custom_domain_signup_enabled, true)
    params = Map.put(@params, "handle", "alice.example.com")
    {:ok, reservation} = Signup.reserve_custom(params)
    lookup = start_supervised!({Agent, fn -> 0 end})

    Application.put_env(:atoll, :identity_resolution_options,
      txt_lookup: fn _ ->
        count = Agent.get_and_update(lookup, &{&1, &1 + 1})
        [["did=" <> if(count == 0, do: reservation.did, else: "did:web:wrong.example.com")]]
      end
    )

    accept_registration()
    assert json_response(request(params), 400)
    row = Repo.get!(Registration, reservation.did)
    assert row.confirmed_at
    refute row.completed_at
    assert Repo.aggregate(Session, :count) == 0
    assert Repo.get!(Head, reservation.did).status == :deactivated

    Application.put_env(:atoll, :identity_resolution_options,
      txt_lookup: fn _ -> [["did=" <> reservation.did]] end
    )

    accept_registration(row.operation)
    assert json_response(request(params), 200)["did"] == reservation.did
  end

  test "custom reservation CLI reads a bounded file and prints no account secrets" do
    Application.put_env(:atoll, :custom_domain_signup_enabled, true)
    params = Map.put(@params, "handle", "alice.example.com")
    path = Path.join(System.tmp_dir!(), "atoll-signup-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    File.write!(path, Jason.encode!(params))
    File.chmod!(path, 0o600)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Accounts.ReserveCustomSignup.run([path])
      end)

    result = Jason.decode!(output)
    assert result["handle"] == params["handle"]
    assert result["dns_value"] == "did=" <> result["did"]
    refute output =~ params["password"]
    refute output =~ params["email"]
    assert Repo.aggregate(Session, :count) == 0

    for contents <- [
          String.duplicate("x", 4097),
          ~s({"handle":"a.example.com","handle":"b.example.com"})
        ] do
      File.write!(path, contents)
      assert_raise Mix.Error, fn -> Mix.Tasks.Atoll.Accounts.ReserveCustomSignup.run([path]) end
    end
  end

  test "fresh signup publishes a persisted genesis before activating and issuing a session" do
    accept_registration()
    response = request(@params) |> json_response(200)
    did = response["did"]
    assert response["handle"] == @params["handle"]
    assert response["active"]
    assert {:ok, %{did: ^did}} = Sessions.authenticate(response["accessJwt"])
    assert {:ok, _} = Sessions.refresh(response["refreshJwt"])
    row = Repo.get!(Registration, did)
    assert row.confirmed_at && row.completed_at
    assert :ok = Operation.verify_genesis(did, row.operation)
    assert {:ok, key} = KeyVault.fetch(did)
    assert {:ok, rotation} = Registrations.rotation_key(did)
    refute key.public == rotation.public
    assert Repo.get!(Profile, did).email == @params["email"]
    assert Repo.get!(Head, did).status == :active
    assert Repo.aggregate(Session, :count) == 1

    conn = %{build_conn() | host: @params["handle"]} |> get("/.well-known/atproto-did")
    assert response(conn, 200) == did
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert request(@params) |> json_response(400) |> Map.fetch!("error") == "InvalidRequest"
  end

  test "timeouts retain reservations and block sessions until exact authenticated retry completes" do
    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 404, ""))
    failed = request(@params)
    assert json_response(failed, 503)["error"] == "ServiceUnavailable"
    assert get_resp_header(failed, "cache-control") == ["no-store"]
    profile = Repo.get_by!(Profile, handle: @params["handle"])
    row = Repo.get!(Registration, profile.did)
    assert is_nil(row.completed_at)
    assert {:error, :signup_pending} = Sessions.create(profile.did, @params["password"])
    assert {:error, :signup_pending} = Sessions.create_for_account(profile.did)
    assert Repo.aggregate(Session, :count) == 0

    assert response(
             get(%{build_conn() | host: @params["handle"]}, "/.well-known/atproto-did"),
             404
           )

    for changed <- [
          Map.put(@params, "password", "wrong password"),
          Map.put(@params, "email", "different@example.com")
        ] do
      assert json_response(request(changed), 400)["error"] == "HandleNotAvailable"
    end

    assert json_response(request(Map.put(@params, "handle", "bob.users.example.com")), 400)[
             "error"
           ] == "InvalidRequest"

    accept_registration(row.operation)
    result = request(@params) |> json_response(200)
    assert result["did"] == row.did
    assert Repo.get!(Registration, row.did).operation == row.operation
    assert Repo.aggregate(Registration, :count) == 1
  end

  test "confirmation and session failure leave signup resumable without another identity" do
    Application.put_env(:atoll, :session_max_count, 0)
    accept_registration()
    assert json_response(request(@params), 429)
    row = Repo.one!(Registration)
    assert row.confirmed_at
    refute row.completed_at
    assert Repo.get!(Head, row.did).status == :deactivated
    Application.put_env(:atoll, :session_max_count, 100)
    accept_registration(row.operation)
    assert json_response(request(@params), 200)["did"] == row.did
  end

  test "recovery key is retained with higher priority and retry cannot replace it" do
    key = SigningKey.generate(:p256)
    {:ok, recovery} = Multikey.to_did_key(key.curve, key.public)
    params = Map.put(@params, "recoveryKey", recovery)
    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 404, ""))
    assert json_response(request(params), 503)
    row = Repo.one!(Registration)
    assert [^recovery, _] = row.operation["rotationKeys"]
    assert json_response(request(@params), 400)
    accept_registration(row.operation)
    assert json_response(request(params), 200)
  end

  test "disabled signup, unsupported domains, invalid input and missing keys do not provision" do
    Application.put_env(:atoll, :signup_enabled, false)
    assert json_response(request(@params), 403)
    Application.put_env(:atoll, :signup_enabled, true)

    for handle <- ["elsewhere.example.com", "a.b.users.example.com", "users.example.com"] do
      assert json_response(request(Map.put(@params, "handle", handle)), 400)["error"] ==
               "UnsupportedDomain"
    end

    assert json_response(request(Map.put(@params, "password", "short")), 400)["error"] ==
             "InvalidPassword"

    assert json_response(request(Map.put(@params, "recoveryKey", "invalid")), 400)
    assert json_response(request(Map.put(@params, "email", "invalid")), 400)
    Application.delete_env(:atoll, :session_signing_key)
    assert json_response(request(@params), 503)
    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))
    Application.delete_env(:atoll, :key_encryption_key)
    assert json_response(request(@params), 503)
    assert Repo.aggregate(Profile, :count) == 0
    assert Repo.aggregate(Registration, :count) == 0
    assert Repo.aggregate(Head, :count) == 0
  end

  test "password replacement during publication invalidates the earlier signup proof" do
    new_password = "replacement account password"

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      operation = Jason.decode!(body)
      {:ok, did} = Operation.genesis_did(operation)
      {:ok, hash} = Atoll.Accounts.Credentials.hash(new_password)

      Repo.get!(Atoll.Accounts.Credential, did)
      |> Ecto.Changeset.change(password_hash: hash)
      |> Repo.update!(log: false)

      Req.Test.expect(__MODULE__, &Req.Test.json(&1, operation))
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert json_response(request(@params), 400)["error"] == "HandleNotAvailable"
    row = Repo.one!(Registration)
    assert row.confirmed_at
    refute row.completed_at
    assert Repo.aggregate(Session, :count) == 0
    accept_registration(row.operation)

    assert json_response(request(Map.put(@params, "password", new_password)), 200)["did"] ==
             row.did
  end

  test "invite-required signup reserves one use across PLC failures and disables new claims" do
    alias Atoll.Accounts.{Invite, Invites, InviteUse}
    Application.put_env(:atoll, :invite_code_required, true)

    description =
      build_conn() |> get("/xrpc/com.atproto.server.describeServer") |> json_response(200)

    assert description["inviteCodeRequired"]
    assert json_response(request(@params), 400)["error"] == "InvalidInviteCode"
    assert Repo.aggregate(Profile, :count) == 0
    {:ok, %{code: code}} = Invites.create()
    params = Map.put(@params, "inviteCode", code)
    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 404, ""))
    assert json_response(request(params), 503)
    row = Repo.one!(Registration)
    assert Repo.get!(Invite, code).remaining == 0
    assert Repo.get!(InviteUse, row.did).code == code
    assert json_response(request(@params), 400)["error"] == "InvalidInviteCode"
    {:ok, :disabled} = Invites.disable(code)

    assert json_response(
             request(
               Map.merge(params, %{
                 "handle" => "bob.users.example.com",
                 "email" => "bob@example.com"
               })
             ),
             400
           )["error"] == "InvalidInviteCode"

    accept_registration(row.operation)
    assert json_response(request(params), 200)["did"] == row.did
    assert Repo.get!(Invite, code).remaining == 0
    assert Repo.aggregate(InviteUse, :count) == 1
  end

  test "normalizes hosted handles and supports accounts without email" do
    accept_registration()

    result =
      request(@params |> Map.delete("email") |> Map.put("handle", "ALICE.USERS.EXAMPLE.COM"))
      |> json_response(200)

    assert result["handle"] == @params["handle"]
    assert is_nil(Repo.get!(Profile, result["did"]).email)
  end

  test "hosted handle route uses the actual host and not forwarded headers" do
    accept_registration()
    result = json_response(request(@params), 200)

    conn =
      %{build_conn() | host: "unknown.users.example.com"}
      |> put_req_header("x-forwarded-host", @params["handle"])
      |> get("/.well-known/atproto-did")

    assert response(conn, 404)
    assert Signup.hosted_handle?(@params["handle"])
    Application.put_env(:atoll, :signup_enabled, false)

    assert response(
             get(%{build_conn() | host: @params["handle"]}, "/.well-known/atproto-did"),
             200
           ) == result["did"]
  end

  defp cleanup_reservation(label, age_days) do
    Application.put_env(:atoll, :custom_domain_signup_enabled, true)

    params =
      Map.merge(@params, %{
        "handle" => label <> ".example.com",
        "email" => label <> "@example.com"
      })

    {:ok, reservation} = Signup.reserve_custom(params)

    Repo.get!(Registration, reservation.did)
    |> Ecto.Changeset.change(
      inserted_at: DateTime.add(DateTime.utc_now(), -age_days * 86_400, :second)
    )
    |> Repo.update!()

    reservation
  end

  defp request(params),
    do:
      %{build_conn() | remote_ip: Process.get(:signup_test_ip)}
      |> put_req_header("content-type", "application/json")
      |> post(@path, Jason.encode!(params))

  defp accept_registration(expected \\ nil) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      operation = Jason.decode!(body)
      {:ok, did} = Operation.genesis_did(operation)
      assert Repo.get!(Registration, did).operation == operation
      assert Repo.get!(Head, did).status == :deactivated
      assert Repo.aggregate(Session, :count) == 0
      if expected, do: assert(operation == expected)

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "GET"
        Req.Test.json(conn, operation)
      end)

      Plug.Conn.send_resp(conn, 200, "")
    end)
  end
end
