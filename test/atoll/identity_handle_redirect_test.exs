defmodule Atoll.IdentityHandleRedirectTest do
  use ExUnit.Case, async: true
  alias Atoll.Identity.{Handle, Resolver}
  @did "did:web:owner.example.com"

  test "follows relative and cross-host HTTPS redirects with fresh destination checks" do
    parent = self()

    request =
      Req.new(
        plug: fn conn ->
          assert Plug.Conn.get_req_header(conn, "authorization") == []
          assert Plug.Conn.get_req_header(conn, "accept") == ["text/plain"]

          case {Plug.Conn.get_req_header(conn, "host"), conn.request_path} do
            {["alice.example.com"], "/.well-known/atproto-did"} ->
              redirect(conn, 302, "/identity")

            {["alice.example.com"], "/identity"} ->
              redirect(conn, 307, "https://identity.example.com/did?name=alice")

            {["identity.example.com"], "/did"} ->
              assert conn.query_string == "name=alice"
              Plug.Conn.send_resp(conn, 200, @did)
          end
        end
      )

    opts = [
      request: request,
      txt_lookup: fn _ -> [] end,
      lookup: fn host ->
        send(parent, {:lookup, host})
        {:ok, {8, 8, 8, 8}}
      end
    ]

    assert Handle.resolve("Alice.Example.com", opts) == {:ok, @did}
    assert_receive {:lookup, "alice.example.com"}
    assert_receive {:lookup, "alice.example.com"}
    assert_receive {:lookup, "identity.example.com"}
  end

  test "supports standard redirect status codes while DID document fetches still reject them" do
    for status <- [301, 302, 303, 307, 308] do
      request =
        Req.new(
          plug: fn conn ->
            if conn.request_path == "/done",
              do: Plug.Conn.send_resp(conn, 200, @did),
              else: redirect(conn, status, "/done")
          end
        )

      assert Handle.resolve("alice.example.com", opts(request)) == {:ok, @did}
      assert {:error, :resolution_failed} = Resolver.resolve_document(@did, opts(request))
    end
  end

  test "rejects unsafe redirect URLs before resolving or requesting their destinations" do
    for location <- [
          "http://target.example.com/did",
          "https://target.example.com:8443/did",
          "https://user:password@target.example.com/did",
          "https://127.0.0.1/did",
          "https://host.local/did",
          "https://target.example.com/did#fragment",
          "https://target.example.com/white space",
          String.duplicate("x", 2049)
        ] do
      request = Req.new(plug: fn conn -> redirect(conn, 302, location) end)

      options =
        Keyword.put(opts(request), :lookup, fn host ->
          assert host == "alice.example.com"
          {:ok, {8, 8, 8, 8}}
        end)

      assert Handle.resolve("alice.example.com", options) == {:error, :handle_not_found}
    end
  end

  test "blocks a public hostname redirecting to a private address and checks same-host rebinding" do
    for target <- ["https://target.example.com/did", "/did"] do
      counter = start_supervised!({Agent, fn -> 0 end}, id: target)

      request =
        Req.new(
          plug: fn conn ->
            assert conn.request_path == "/.well-known/atproto-did"
            redirect(conn, 302, target)
          end
        )

      options =
        Keyword.put(opts(request), :lookup, fn _ ->
          case Agent.get_and_update(counter, &{&1, &1 + 1}) do
            0 -> {:ok, {8, 8, 8, 8}}
            _ -> {:ok, {127, 0, 0, 1}}
          end
        end)

      assert Handle.resolve("alice.example.com", options) == {:error, :handle_not_found}
      assert Agent.get(counter, & &1) == 2
    end
  end

  test "bounds loops, rejects ambiguous locations, and enforces body limits at each hop" do
    counter = start_supervised!({Agent, fn -> 0 end})

    request =
      Req.new(
        plug: fn conn ->
          Agent.update(counter, &(&1 + 1))
          redirect(conn, 302, "/loop")
        end
      )

    assert Handle.resolve("alice.example.com", opts(request)) == {:error, :handle_not_found}
    assert Agent.get(counter, & &1) == 4

    for headers <- [[], [{"location", "/a"}, {"location", "/b"}]] do
      request =
        Req.new(
          plug: fn conn ->
            %{conn | resp_headers: headers} |> Plug.Conn.send_resp(302, "")
          end
        )

      assert Handle.resolve("alice.example.com", opts(request)) == {:error, :handle_not_found}
    end

    for oversized_redirect? <- [true, false] do
      request =
        Req.new(
          plug: fn conn ->
            cond do
              oversized_redirect? ->
                conn
                |> Plug.Conn.put_resp_header("location", "/done")
                |> Plug.Conn.send_resp(302, String.duplicate("x", 4097))

              conn.request_path == "/done" ->
                Plug.Conn.send_resp(conn, 200, String.duplicate("x", 4097))

              true ->
                redirect(conn, 302, "/done")
            end
          end
        )

      assert Handle.resolve("alice.example.com", opts(request)) == {:error, :handle_not_found}
    end
  end

  defp opts(request),
    do: [request: request, txt_lookup: fn _ -> [] end, lookup: fn _ -> {:ok, {8, 8, 8, 8}} end]

  defp redirect(conn, status, target),
    do: conn |> Plug.Conn.put_resp_header("location", target) |> Plug.Conn.send_resp(status, "")
end
