defmodule AtollWeb.AdminMessageControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Repo, Repositories, SigningKey}
  alias Atoll.Accounts.{AdminMessage, Profile}
  alias Atoll.Moderation.Audit

  @path "/xrpc/com.atproto.admin.sendEmail"
  @did "did:web:operator-message.example.com"
  @sender "did:web:operator.example.com"
  @secret "operator-message-secret-at-least-32-bytes"

  setup %{conn: conn} do
    previous =
      Map.new(
        [:admin_password, :email_worker, :email_delivery_options],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    Application.put_env(:atoll, :admin_password, @secret)

    Application.put_env(:atoll, :email_worker,
      url: "https://worker.example.com/send",
      token: "worker-secret"
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
      handle: "operator-message.example.com",
      email: "recipient@example.com"
    })

    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 79, div(id, 256), rem(id, 256)}}}
  end

  test "sends only to the stored address through the Worker and audits acceptance", c do
    seq = Atoll.Repositories.Events.latest_seq()

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "worker.example.com"
      assert get_req_header(conn, "authorization") == ["Bearer worker-secret"]
      {:ok, body, conn} = read_body(conn)

      assert Jason.decode!(body) == %{
               "to" => "recipient@example.com",
               "subject" => "Private subject",
               "text" => "Private content"
             }

      [id] = get_req_header(conn, "idempotency-key")
      assert {:ok, %{entries: [prepared]}} = Audit.list()
      assert prepared.after == %{"status" => "prepared"}
      assert prepared.requested["messageId"] == id
      send_resp(conn, 202, "provider-private-response")
    end)

    response = auth(c.conn) |> post(@path, params())
    assert json_response(response, 200) == %{"sent" => true}
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert {:ok, %{entries: [prepared, accepted]}} = Audit.list()
    assert accepted.requested == prepared.requested
    assert accepted.requested["senderDid"] == @sender
    assert accepted.requested["comment"] == "Private operator context"
    assert accepted.after == %{"status" => "accepted"}
    history = Jason.encode!([prepared, accepted])

    for secret <- [
          "Private subject",
          "Private content",
          "recipient@example.com",
          "worker-secret",
          "provider-private-response"
        ],
        do: refute(history =~ secret)

    assert Atoll.Repositories.Events.latest_seq() == seq
  end

  test "missing subjects use a default and inactive accounts can receive operator messages", c do
    for status <- [:deactivated, :suspended, :takendown] do
      {:ok, _} = Repositories.set_status(@did, status)

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = read_body(conn)
        assert Jason.decode!(body)["subject"] == "Message from your PDS operator"
        send_resp(conn, 204, "")
      end)

      assert auth(c.conn) |> post(@path, Map.delete(params(), "subject")) |> json_response(200) ==
               %{"sent" => true}
    end
  end

  test "delivery failures are audited without leaking upstream details", c do
    for {status, outcome} <- [{403, "rejected"}, {503, "unavailable"}] do
      Req.Test.expect(__MODULE__, &send_resp(&1, status, "private upstream details"))
      response = auth(c.conn) |> post(@path, params())
      assert json_response(response, 503)["error"] == "ServiceUnavailable"
      refute response.resp_body =~ "private upstream details"
      {:ok, %{entries: entries}} = Audit.list()
      assert List.last(entries).after == %{"status" => outcome}
    end

    Application.delete_env(:atoll, :email_worker)
    assert auth(c.conn) |> post(@path, params()) |> json_response(503)
    {:ok, %{entries: entries}} = Audit.list()
    assert List.last(entries).after == %{"status" => "not_configured"}
  end

  test "authorization, input bounds and recipient lookup prevent delivery", c do
    assert c.conn |> post(@path, params()) |> json_response(401)
    assert auth(c.conn) |> get(@path) |> json_response(405)

    for invalid <- [
          Map.put(params(), "subject", "bad\r\nsubject"),
          Map.put(params(), "content", ""),
          Map.put(params(), "content", String.duplicate("x", 12_001)),
          Map.put(params(), "comment", String.duplicate("x", 2001)),
          Map.put(params(), "senderDid", "invalid"),
          Map.put(params(), "to", "arbitrary@example.com")
        ] do
      assert {:error, :invalid_request} = AdminMessage.deliver(invalid)
    end

    assert {:error, :admin_account_not_found} =
             AdminMessage.deliver(
               Map.put(params(), "recipientDid", "did:web:missing.example.com")
             )

    Repo.get!(Profile, @did) |> Ecto.Changeset.change(email: nil) |> Repo.update!()
    assert {:error, :invalid_email} = AdminMessage.deliver(params())
    assert {:ok, %{entries: []}} = Audit.list()
  end

  test "an interrupted delivery leaves a prepared attempt rather than claiming success" do
    Req.Test.expect(__MODULE__, fn _ -> raise "simulated interruption" end)
    assert_raise RuntimeError, "simulated interruption", fn -> AdminMessage.deliver(params()) end
    assert {:ok, %{entries: [entry]}} = Audit.list()
    assert entry.after == %{"status" => "prepared"}
  end

  defp params,
    do: %{
      "recipientDid" => @did,
      "senderDid" => @sender,
      "subject" => "Private subject",
      "content" => "Private content",
      "comment" => "Private operator context"
    }

  defp auth(conn),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Basic " <> Base.encode64("admin:" <> @secret))
end
