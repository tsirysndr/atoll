defmodule AtollWeb.ErrorJSONTest do
  use AtollWeb.ConnCase, async: false

  test "renders 404" do
    assert AtollWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert AtollWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end

  test "XRPC errors are sanitized even when exception assigns contain secrets" do
    for path <- ["/xrpc/com.example.test", "/%78rpc/com.example.test"],
        {status, error} <- [
          {400, "InvalidRequest"},
          {406, "NotAcceptable"},
          {413, "PayloadTooLarge"},
          {500, "InternalServerError"},
          {503, "ServiceUnavailable"}
        ] do
      assigns = %{
        conn: build_conn(:get, path),
        reason: RuntimeError.exception("secret"),
        stack: [:private_stack],
        kind: :error,
        status: status
      }

      result = AtollWeb.ErrorJSON.render("#{status}.json", assigns)
      assert result == %{error: error, message: Plug.Conn.Status.reason_phrase(status)}
      refute Jason.encode!(result) =~ "secret"
    end
  end

  test "framework content negotiation errors use XRPC JSON" do
    {406, headers, body} =
      assert_error_sent 406, fn ->
        build_conn()
        |> put_req_header("accept", "text/html")
        |> get("/xrpc/com.atproto.server.describeServer")
      end

    assert {"content-type", "application/json; charset=utf-8"} in headers
    assert Jason.decode!(body) == %{"error" => "NotAcceptable", "message" => "Not Acceptable"}
  end

  test "framework query decoding errors use XRPC JSON" do
    {400, _headers, body} =
      assert_error_sent 400, fn ->
        get(build_conn(), "/xrpc/com.atproto.server.describeServer?bad=%FF")
      end

    assert Jason.decode!(body) == %{"error" => "InvalidRequest", "message" => "Bad Request"}
  end

  test "unexpected controller failures return a sanitized 500 response" do
    previous = Application.fetch_env!(:atoll, :pds)
    on_exit(fn -> Application.put_env(:atoll, :pds, previous) end)
    Application.put_env(:atoll, :pds, private_setting: "must-not-leak")

    {500, headers, body} =
      assert_error_sent 500, fn ->
        get(build_conn(), "/xrpc/com.atproto.server.describeServer")
      end

    assert Jason.decode!(body) == %{
             "error" => "InternalServerError",
             "message" => "Internal Server Error"
           }

    assert {"content-type", "application/json; charset=utf-8"} in headers
    assert {"access-control-allow-origin", "*"} in headers
    refute body =~ "must-not-leak"
  end

  test "unknown non-XRPC routes retain the standard JSON error shape" do
    conn = get(build_conn(), "/not-an-api-route")
    assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}}
  end
end
