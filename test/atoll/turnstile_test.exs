defmodule Atoll.Accounts.TurnstileTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.Accounts.Turnstile

  setup do
    keys = [:turnstile, :turnstile_request_options, :signup_enabled]
    previous = Map.new(keys, &{&1, Application.fetch_env(:atoll, &1)})

    Application.put_env(:atoll, :turnstile,
      site_key: "site",
      secret_key: "secret",
      hostnames: ["rocksky.social"]
    )

    Application.put_env(:atoll, :turnstile_request_options, plug: {Req.Test, __MODULE__})
    Application.put_env(:atoll, :signup_enabled, true)

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

  test "partial configuration fails at startup" do
    assert_raise RuntimeError, fn ->
      Turnstile.config_from_env!(%{"ATOLL_TURNSTILE_SITE_KEY" => "site"})
    end

    assert_raise RuntimeError, fn ->
      Turnstile.config_from_env!(%{"ATOLL_TURNSTILE_SECRET_KEY" => "secret"})
    end
  end

  test "missing and malformed tokens cannot reach provisioning, including invite and DID requests" do
    for token <- [nil, "", 123, String.duplicate("a", 2049)] do
      assert {:error, :turnstile_failed} =
               Atoll.Accounts.Signup.create(%{
                 "turnstileToken" => token,
                 "inviteCode" => "not-a-bypass"
               })
    end

    base = %{
      "handle" => "visitor.example.com",
      "password" => "correct horse battery",
      "email" => "visitor@example.com"
    }

    for params <- [base, Map.put(base, "did", "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa")] do
      conn = build_conn() |> put_req_header("content-type", "application/json")

      conn =
        if params["did"], do: put_req_header(conn, "authorization", "Bearer a.b.c"), else: conn

      response = post(conn, "/xrpc/com.atproto.server.createAccount", Jason.encode!(params))
      assert response.status == 400
      assert json_response(response, 400)["error"] == "TurnstileFailed"
    end
  end

  test "direct JSON registration accepts the token extension and validates it" do
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"success" => false}))

    response =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/xrpc/com.atproto.server.createAccount",
        Jason.encode!(%{
          "handle" => "visitor.example.com",
          "password" => "correct horse battery",
          "email" => "visitor@example.com",
          "turnstileToken" => "invalid-token"
        })
      )

    assert json_response(response, 400)["error"] == "TurnstileFailed"
  end

  test "valid challenges are bound to action and allowed hostname" do
    valid = %{"success" => true, "hostname" => "rocksky.social", "action" => "signup"}

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "challenges.cloudflare.com"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"secret" => "secret", "response" => "token"}
      Req.Test.json(conn, valid)
    end)

    assert :ok = Turnstile.verify("token")

    for body <- [
          Map.put(valid, "hostname", "attacker.example"),
          Map.put(valid, "action", "login"),
          Map.put(valid, "success", false)
        ] do
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, body))
      assert {:error, :turnstile_failed} = Turnstile.verify("token")
    end
  end

  test "provider timeouts and errors fail closed" do
    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))
    assert {:error, :turnstile_unavailable} = Turnstile.verify("token")
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)
    assert {:error, :turnstile_unavailable} = Turnstile.verify("token")
  end
end
