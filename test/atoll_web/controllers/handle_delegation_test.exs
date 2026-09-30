defmodule AtollWeb.HandleDelegationTest do
  @moduledoc """
  A handle namespace shared with another PDS: this server owns the wildcard, so
  it answers handle resolution and the TLS ask endpoint for the other server's
  accounts as well as its own.
  """
  use AtollWeb.ConnCase, async: false

  @did "did:plc:4zc47fuogx2rdgxolokayzaw"

  setup do
    delegates = Application.get_env(:atoll, :handle_delegates)
    transport = Application.get_env(:atoll, :handle_delegate_transport)
    Application.put_env(:atoll, :handle_delegates, ["https://sibling.example.test"])
    Application.put_env(:atoll, :handle_delegate_transport, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      restore(:handle_delegates, delegates)
      restore(:handle_delegate_transport, transport)
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:atoll, key)
  defp restore(key, value), do: Application.put_env(:atoll, key, value)

  defp answers(did) do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/xrpc/com.atproto.identity.resolveHandle"
      Req.Test.json(conn, %{did: did})
    end)
  end

  defp refuses do
    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 400, ~s({"error":"UnableToResolveHandle"}))
    end)
  end

  test "a delegate's handle resolves here", %{conn: conn} do
    answers(@did)

    response =
      %{conn | host: "delegated.example.test"}
      |> get("/.well-known/atproto-did")

    assert response(response, 200) == @did
    assert get_resp_header(response, "access-control-allow-origin") == ["*"]
    assert ["text/plain" <> _] = get_resp_header(response, "content-type")
  end

  test "a delegate's handle is issued a certificate", %{conn: conn} do
    answers(@did)
    assert conn |> get("/tls-check", %{domain: "delegated.example.test"}) |> response(200) == ""
  end

  test "resolveHandle answers for a delegate's account", %{conn: conn} do
    answers(@did)

    assert conn
           |> get("/xrpc/com.atproto.identity.resolveHandle", %{handle: "delegated.example.test"})
           |> json_response(200) == %{"did" => @did}
  end

  test "a handle no delegate claims is still refused", %{conn: conn} do
    refuses()

    assert %{conn | host: "nobody.example.test"}
           |> get("/.well-known/atproto-did")
           |> response(404)

    refuses()
    assert conn |> get("/tls-check", %{domain: "nobody.example.test"}) |> response(404)
  end

  test "a host outside this namespace is never delegated", %{conn: conn} do
    # No stub is installed, so any outbound request would fail the test.
    assert %{conn | host: "alice.elsewhere.test"}
           |> get("/.well-known/atproto-did")
           |> response(404)

    assert conn |> get("/tls-check", %{domain: "alice.elsewhere.test"}) |> response(404)
  end
end
