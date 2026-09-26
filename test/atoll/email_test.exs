defmodule Atoll.EmailTest do
  use ExUnit.Case, async: false
  alias Atoll.Email

  @message %{to: "owner@example.com", subject: "Confirm your email", text: "Your code is EXAMPLE"}
  @key "opaque-message-id-123"

  setup do
    previous = Application.get_env(:atoll, :email_worker)

    Application.put_env(:atoll, :email_worker,
      url: "https://email.example.com/send",
      token: "secret"
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:atoll, :email_worker, previous),
        else: Application.delete_env(:atoll, :email_worker)
    end)
  end

  test "posts the shared contract with stable idempotency and bearer authentication" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/send"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer secret"]
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == [@key]
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "to" => @message.to,
               "subject" => @message.subject,
               "text" => @message.text
             }

      Plug.Conn.send_resp(conn, 202, "")
    end)

    assert :ok = Email.deliver(@message, @key, plug: {Req.Test, __MODULE__})
  end

  test "does not retry or follow redirects and sanitizes failures" do
    for {status, expected} <- [
          {302, :email_delivery_rejected},
          {401, :email_delivery_rejected},
          {429, :email_delivery_unavailable},
          {503, :email_delivery_unavailable}
        ] do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://other.example.com")
        |> Plug.Conn.send_resp(status, "sensitive provider error")
      end)

      assert {:error, ^expected} = Email.deliver(@message, @key, plug: {Req.Test, __MODULE__})
    end

    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))

    assert {:error, :email_delivery_unavailable} =
             Email.deliver(@message, @key, plug: {Req.Test, __MODULE__})
  end

  test "disabled delivery and invalid messages never reach transport" do
    for message <- [
          %{},
          %{@message | to: "bad"},
          %{@message | subject: "Hi\r\nBcc: bad"},
          %{@message | text: String.duplicate("x", 65_537)}
        ] do
      assert {:error, :invalid_email} = Email.deliver(message, @key)
    end

    assert {:error, :invalid_email} = Email.deliver(@message, "bad\r\nkey")
    Application.delete_env(:atoll, :email_worker)
    assert {:error, :email_not_configured} = Email.deliver(@message, @key)
  end

  test "validates runtime configuration without reflecting credentials" do
    assert Email.Config.parse!(%{}) == []

    assert Email.Config.parse!(%{
             "ATOLL_EMAIL_WORKER_URL" => "https://mail.example.com/send",
             "ATOLL_EMAIL_WORKER_TOKEN" => "secret"
           }) ==
             [url: "https://mail.example.com/send", token: "secret"]

    for url <- [
          nil,
          "",
          "http://mail.example.com",
          "https://secret@mail.example.com",
          "https://mail.example.com?token=secret",
          "https://mail.example.com#fragment"
        ] do
      error =
        assert_raise RuntimeError, fn ->
          Email.Config.parse!(%{
            "ATOLL_EMAIL_WORKER_URL" => url,
            "ATOLL_EMAIL_WORKER_TOKEN" => "secret"
          })
        end

      refute error.message =~ "secret"
    end

    assert_raise RuntimeError, fn ->
      Email.Config.parse!(%{"ATOLL_EMAIL_WORKER_URL" => "https://mail.example.com"})
    end
  end

  test "preserves config settings and replaces environment overrides as a complete pair" do
    settings = [url: "https://configured.example.com/send", token: "config-secret"]
    assert Email.Config.parse!(%{}, settings) == settings

    assert Email.Config.parse!(
             %{
               "ATOLL_EMAIL_WORKER_URL" => "https://override.example.com/send",
               "ATOLL_EMAIL_WORKER_TOKEN" => "override-secret"
             },
             settings
           ) == [url: "https://override.example.com/send", token: "override-secret"]

    for env <- [
          %{"ATOLL_EMAIL_WORKER_URL" => "https://override.example.com/send"},
          %{"ATOLL_EMAIL_WORKER_TOKEN" => "override-secret"},
          %{"ATOLL_EMAIL_WORKER_URL" => ""}
        ] do
      assert_raise RuntimeError, fn -> Email.Config.parse!(env, settings) end
    end

    assert_raise RuntimeError, fn ->
      Email.Config.parse!(%{}, url: "http://configured.example.com", token: "config-secret")
    end
  end
end
