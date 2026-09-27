defmodule Atoll.RelaysTest do
  use Atoll.DataCase, async: false
  alias Atoll.Relays

  setup do
    previous =
      Map.new([:relay_urls, :relay_request_options], &{&1, Application.fetch_env(:atoll, &1)})

    Application.put_env(:atoll, :relay_urls, ["https://relay.example.com"])

    Application.put_env(:atoll, :relay_request_options,
      hostname: "pds.example.com",
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    :ok
  end

  test "posts only the hostname and deduplicates normalized relay origins" do
    Application.put_env(
      :atoll,
      :relay_urls,
      Relays.from_env!("https://RELAY.example.com/,https://relay.example.com")
    )

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/xrpc/com.atproto.sync.requestCrawl"
      assert conn.host == "relay.example.com"
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      assert Plug.Conn.get_req_header(conn, "cookie") == []
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"hostname" => "pds.example.com"}
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:ok, [%{relay: "https://relay.example.com", outcome: :accepted}]} = request()
  end

  test "one relay failure does not prevent another configured relay from being contacted" do
    Application.put_env(:atoll, :relay_urls, [
      "https://one.example.com",
      "https://two.example.com"
    ])

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "one.example.com"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, ~s({"error":"HostBanned","message":"private"}))
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "two.example.com"
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert {:ok, [%{outcome: :host_banned}, %{outcome: :accepted}]} = request()
  end

  test "redirects, errors and oversized bodies are bounded without leaking relay details" do
    for {status, body, expected} <- [
          {302, "redirect", :rejected},
          {429, "private", :unavailable},
          {503, "private", :unavailable},
          {403, "private", :rejected},
          {200, String.duplicate("x", 4097), :rejected}
        ] do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://another.example.com")
        |> Plug.Conn.send_resp(status, body)
      end)

      assert {:ok, [%{outcome: ^expected} = result]} = request()
      assert Enum.sort(Map.keys(result)) == [:outcome, :relay]
    end

    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))
    assert {:ok, [%{outcome: :unavailable}]} = request()
  end

  test "validates the entire configured batch and hostname before making network requests" do
    assert Relays.from_env!(nil) == []

    for value <- [
          "http://relay.example.com",
          "https://user:secret@relay.example.com",
          "https://relay.example.com:8443",
          "https://relay.example.com/path",
          "https://relay.example.com?secret=x",
          "https://localhost",
          "https://127.0.0.1",
          "https://relay.invalid",
          Enum.join(List.duplicate("https://relay.example.com", 11), ",")
        ] do
      assert_raise ArgumentError, fn -> Relays.from_env!(value) end
    end

    Application.put_env(:atoll, :relay_urls, [
      "https://relay.example.com",
      "http://bad.example.com"
    ])

    assert request() == {:error, :relay_configuration_invalid}
    Application.put_env(:atoll, :relay_urls, [])
    assert request() == {:error, :relay_configuration_invalid}
    Application.put_env(:atoll, :relay_urls, ["https://relay.example.com"])

    for hostname <- [
          nil,
          "localhost",
          "pds.example.com:4000",
          "https://pds.example.com",
          "host.local"
        ] do
      assert Relays.request_crawl(hostname: hostname, plug: {Req.Test, __MODULE__}) ==
               {:error, :relay_configuration_invalid}
    end
  end

  test "operator command prints outcomes and exits with an error for unsuccessful requests" do
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 202, ""))
    output = ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Atoll.Relays.RequestCrawl.run([]) end)

    assert Jason.decode!(String.trim(output)) == %{
             "relays" => [%{"relay" => "https://relay.example.com", "outcome" => "accepted"}]
           }

    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 503, "private relay failure"))

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert_raise Mix.Error, fn -> Mix.Tasks.Atoll.Relays.RequestCrawl.run([]) end
      end)

    refute output =~ "private relay failure"

    assert_raise Mix.Error, fn ->
      Mix.Tasks.Atoll.Relays.RequestCrawl.run(["--hostname", "other.example.com"])
    end
  end

  defp request, do: Relays.request_crawl(Application.fetch_env!(:atoll, :relay_request_options))

  test "operator audit precedes network calls and links sanitized completion outcomes" do
    Application.put_env(:atoll, :relay_urls, [
      "https://RELAY.example.com/",
      "https://other.example.com"
    ])

    Req.Test.expect(__MODULE__, fn conn ->
      refute Repo.in_transaction?()
      [attempt] = audit_rows()
      assert attempt.after_state == %{"phase" => "attempt"}

      assert attempt.requested == %{
               "relays" => ["https://relay.example.com", "https://other.example.com"]
             }

      Plug.Conn.send_resp(conn, 200, "private success details")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 400, ~s({"error":"HostBanned","message":"private reason"}))
    end)

    assert {:ok, [%{outcome: :accepted}, %{outcome: :host_banned}]} = audited_request()
    [attempt, completed] = audit_rows()
    assert completed.requested == %{"attemptId" => Integer.to_string(attempt.id)}

    assert completed.after_state == %{
             "phase" => "completed",
             "results" => [
               %{"relay" => "https://relay.example.com", "outcome" => "accepted"},
               %{"relay" => "https://other.example.com", "outcome" => "host_banned"}
             ]
           }

    for row <- [attempt, completed] do
      assert row.did == nil
      assert row.actor == "operator"
      assert row.operation == "atoll.relays.requestCrawl"
      assert row.subject == %{"kind" => "relayAnnouncement", "hostname" => "pds.example.com"}
      refute Jason.encode!([row.requested, row.before_state, row.after_state]) =~ "private"
    end
  end

  test "attempt audit failure prevents network requests" do
    Repo.query!(
      "ALTER TABLE moderation_audit_entries ADD CONSTRAINT reject_crawl_audit CHECK (operation <> 'atoll.relays.requestCrawl')"
    )

    Req.Test.stub(__MODULE__, fn _ -> flunk("audit failure must prevent relay requests") end)
    assert audited_request() == {:error, :relay_audit_unavailable}

    assert_raise Mix.Error, ~r/no relay requests were sent/, fn ->
      Mix.Tasks.Atoll.Relays.RequestCrawl.run([])
    end

    assert audit_rows() == []
  end

  test "completion audit failure preserves the attempt and reports uncertain history" do
    Repo.query!(
      "ALTER TABLE moderation_audit_entries ADD CONSTRAINT reject_crawl_completion CHECK (operation <> 'atoll.relays.requestCrawl' OR after_state->>'phase' <> 'completed')"
    )

    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 200, ""))

    assert_raise Mix.Error, ~r/requests were sent, but outcomes could not be audited/, fn ->
      Mix.Tasks.Atoll.Relays.RequestCrawl.run([])
    end

    [attempt] = audit_rows()
    assert attempt.after_state == %{"phase" => "attempt"}
  end

  test "interrupted batches leave an attempt without claiming completion" do
    Req.Test.expect(__MODULE__, fn _ -> raise "interrupted transport" end)
    assert_raise RuntimeError, "interrupted transport", fn -> audited_request() end
    [attempt] = audit_rows()
    assert attempt.after_state == %{"phase" => "attempt"}
  end

  test "configuration failures and nested transactions cannot create misleading attempts" do
    assert {:ok, {:error, :relay_audit_transaction}} =
             Repo.transaction(fn -> audited_request() end)

    Application.put_env(:atoll, :relay_urls, ["http://bad.example.com"])
    assert audited_request() == {:error, :relay_configuration_invalid}
    assert audit_rows() == []
  end

  defp audited_request,
    do: Relays.request_crawl_audited(Application.fetch_env!(:atoll, :relay_request_options))

  defp audit_rows, do: Repo.all(from a in Atoll.Moderation.AuditEntry, order_by: a.id)
end
