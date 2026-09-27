defmodule Atoll.ProxyTransportTest do
  use ExUnit.Case, async: true
  alias Atoll.Proxy.{Target, Transport}
  import Plug.Conn

  @nsid "app.bsky.feed.getTimeline"

  def run(req), do: Req.Request.get_private(req, :proxy_test_adapter).(req)

  defp adapter(fun) do
    Req.new(adapter: __MODULE__) |> Req.Request.put_private(:proxy_test_adapter, fun)
  end

  defp target(address \\ {8, 8, 8, 8}) do
    %Target{
      audience: "did:web:service.example.com#bsky_appview",
      uri: URI.parse("https://service.example.com:8443"),
      address: address
    }
  end

  test "pins DNS, preserves TLS authority and repeated query values, and filters credentials" do
    query = "uris=at%3A%2F%2Fa&uris=at%3A%2F%2Fb&cursor=a%2Bb"

    req =
      Req.new(
        plug: fn conn ->
          assert conn.host == "8.8.8.8"
          assert conn.port == 8443
          assert conn.method == "GET"
          assert conn.request_path == "/xrpc/" <> @nsid
          assert conn.query_string == query
          assert get_req_header(conn, "host") == ["service.example.com:8443"]
          assert get_req_header(conn, "authorization") == ["Bearer service.jwt"]
          assert get_req_header(conn, "accept-encoding") == ["identity"]
          assert get_req_header(conn, "atproto-accept-labelers") == ["did:web:labels.example.com"]

          for name <- ~w(cookie dpop atproto-proxy x-forwarded-for),
              do: assert(get_req_header(conn, name) == [])

          conn
          |> put_resp_header("set-cookie", "session=remote")
          |> put_resp_header("location", "https://elsewhere.example.com")
          |> put_resp_header("atproto-repo-rev", "revision")
          |> put_resp_content_type("application/json")
          |> send_resp(200, "{\"ok\":true}")
        end
      )
      |> Req.Request.append_request_steps(
        inspect_options: fn req ->
          assert req.options.connect_options[:hostname] == "service.example.com"
          assert req.options.redirect == false
          assert req.options.retry == false
          assert req.options.raw == true
          assert req.options.compressed == false
          req
        end
      )

    headers = [
      {"authorization", "Bearer caller"},
      {"cookie", "secret"},
      {"dpop", "proof"},
      {"atproto-proxy", "other"},
      {"x-forwarded-for", "127.0.0.1"},
      {"atproto-accept-labelers", "did:web:labels.example.com"}
    ]

    assert {:ok, response} =
             Transport.send(target(), :get, @nsid, query, headers, "", "service.jwt",
               request: req
             )

    assert response.body == "{\"ok\":true}"
    assert response.headers["atproto-repo-rev"] == ["revision"]
    refute Map.has_key?(response.headers, "set-cookie")
    refute Map.has_key?(response.headers, "location")
  end

  test "forwards raw POST bytes and returns service errors unchanged" do
    body = <<0, 255, 128, 1>>

    req =
      Req.new(
        plug: fn conn ->
          assert conn.method == "POST"
          assert {:ok, ^body, conn} = read_body(conn)
          assert get_req_header(conn, "content-type") == ["application/octet-stream"]
          conn |> put_resp_header("retry-after", "30") |> send_resp(429, "slow down")
        end
      )

    assert {:ok, %{status: 429, body: "slow down", headers: %{"retry-after" => ["30"]}}} =
             Transport.send(
               target(),
               :post,
               "com.example.doThing",
               "",
               [{"content-type", "application/octet-stream"}],
               body,
               "jwt", request: req)
  end

  test "rejects redirects and compressed responses without following or decoding them" do
    for {status, encoding, expected} <- [
          {302, nil, :proxy_response_status},
          {200, "gzip", :proxy_content_encoding}
        ] do
      req =
        Req.new(
          plug: fn conn ->
            conn =
              if encoding, do: put_resp_header(conn, "content-encoding", encoding), else: conn

            conn
            |> put_resp_header("location", "http://127.0.0.1/secret")
            |> send_resp(status, "payload")
          end
        )

      assert {:error, ^expected} =
               Transport.send(target(), :get, @nsid, "", [], "", "jwt", request: req)
    end
  end

  test "bounds response bytes, including chunked responses without a Content-Length" do
    req =
      Req.new(
        plug: fn conn -> send_resp(conn, 200, String.duplicate("x", 8 * 1024 * 1024 + 1)) end
      )

    assert {:error, :proxy_response_too_large} =
             Transport.send(target(), :get, @nsid, "", [], "", "jwt", request: req)

    # Exercise the real streaming callback with separate network-sized chunks.
    req =
      adapter(fn req ->
        collect = req.into

        {_, resp} =
          Enum.reduce(1..128, {req, Req.Response.new()}, fn _, pair ->
            assert {:cont, pair} = collect.({:data, String.duplicate("x", 65_536)}, pair)
            pair
          end)

        assert {:halt, pair} = collect.({:data, "!"}, {req, resp})
        pair
      end)

    assert {:error, :proxy_response_too_large} =
             Transport.send(target(), :get, @nsid, "", [], "", "jwt", request: req)
  end

  test "rejects malformed or oversized requests before transport" do
    req = Req.new(plug: fn _ -> flunk("must not send") end)

    for {method, nsid, query, headers, body, jwt} <- [
          {:delete, @nsid, "", [], "", "jwt"},
          {:get, "../admin", "", [], "", "jwt"},
          {:get, @nsid, "a=1#fragment", [], "", "jwt"},
          {:get, @nsid, "a=\r\n", [], "", "jwt"},
          {:get, @nsid, String.duplicate("x", 8193), [], "", "jwt"},
          {:get, @nsid, "", [], "body", "jwt"},
          {:post, @nsid, "", [], String.duplicate("x", 2 * 1024 * 1024 + 1), "jwt"},
          {:get, @nsid, "", [{"accept", "x\r\ny"}], "", "jwt"},
          {:get, @nsid, "", [{"Accept", "x"}, {"accept", "y"}], "", "jwt"},
          {:get, @nsid, "", [], "", "bad\r\njwt"}
        ] do
      assert {:error, :invalid_proxy_request} =
               Transport.send(target(), method, nsid, query, headers, body, jwt, request: req)
    end

    assert {:error, :invalid_proxy_request} =
             Transport.send(target({127, 0, 0, 1}), :get, @nsid, "", [], "", "jwt", request: req)
  end

  test "classifies network timeouts and transport errors" do
    for {reason, expected} <- [{:timeout, :proxy_timeout}, {:closed, :proxy_unavailable}] do
      req = adapter(fn req -> {req, %Req.TransportError{reason: reason}} end)

      assert {:error, ^expected} =
               Transport.send(target(), :get, @nsid, "", [], "", "jwt", request: req)
    end
  end

  test "preserves chunk order at the exact response limit" do
    req =
      adapter(fn req ->
        first = String.duplicate("a", 4 * 1024 * 1024)
        last = String.duplicate("b", 4 * 1024 * 1024)
        assert {:cont, pair} = req.into.({:data, first}, {req, Req.Response.new(status: 200)})
        assert {:cont, pair} = req.into.({:data, last}, pair)
        pair
      end)

    assert {:ok, %{body: body}} =
             Transport.send(target(), :get, @nsid, "", [], "", "jwt", request: req)

    assert byte_size(body) == 8 * 1024 * 1024
    assert binary_part(body, 0, 4 * 1024 * 1024) == String.duplicate("a", 4 * 1024 * 1024)

    assert binary_part(body, 4 * 1024 * 1024, 4 * 1024 * 1024) ==
             String.duplicate("b", 4 * 1024 * 1024)
  end

  test "pins IPv6 while retaining the service hostname" do
    address = {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}

    req =
      adapter(fn req ->
        assert req.url.host == to_string(:inet.ntoa(address))
        assert req.options.connect_options[:transport_opts] == [inet6: true, inet4: false]
        assert req.options.connect_options[:hostname] == "service.example.com"
        {req, Req.Response.new(status: 204)}
      end)

    assert {:ok, %{status: 204, body: ""}} =
             Transport.send(target(address), :get, @nsid, "", [], "", "jwt", request: req)
  end
end
