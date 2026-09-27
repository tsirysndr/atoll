defmodule AtollWeb.ServerControllerTest do
  use AtollWeb.ConnCase, async: false

  test "describes the configured server without authentication", %{conn: conn} do
    body = get(conn, ~p"/xrpc/com.atproto.server.describeServer") |> json_response(200)

    assert %{
             "did" => "did:web:pds.example.test",
             "availableUserDomains" => [".example.test"],
             "blobUploadLimit" => 5_242_880
           } = body

    refute Map.has_key?(body, "links")
    refute Map.has_key?(body, "contact")
  end

  test "includes configured policy links and operator contact", %{conn: conn} do
    previous = Application.fetch_env!(:atoll, :pds)

    on_exit(fn -> Application.put_env(:atoll, :pds, previous) end)

    server =
      Atoll.ServerConfig.parse!(
        %{
          "ATOLL_PDS_DID" => "did:web:pds.example.test",
          "ATOLL_AVAILABLE_USER_DOMAINS" => ".example.test",
          "ATOLL_PRIVACY_POLICY_URL" => "https://pds.example.test/privacy",
          "ATOLL_TERMS_OF_SERVICE_URL" => "https://pds.example.test/terms",
          "ATOLL_CONTACT_EMAIL" => "Admin@Example.test"
        },
        false
      )

    Application.put_env(:atoll, :pds, server.pds)
    body = get(conn, ~p"/xrpc/com.atproto.server.describeServer") |> json_response(200)

    assert body["links"] == %{
             "privacyPolicy" => "https://pds.example.test/privacy",
             "termsOfService" => "https://pds.example.test/terms"
           }

    assert body["contact"] == %{"email" => "admin@example.test"}

    for {name, value} <- [
          {"ATOLL_PRIVACY_POLICY_URL", "http://insecure.example.test"},
          {"ATOLL_TERMS_OF_SERVICE_URL", "not a url"},
          {"ATOLL_CONTACT_EMAIL", "not-an-address"}
        ] do
      assert_raise RuntimeError, ~r/#{name}/, fn ->
        Atoll.ServerConfig.parse!(%{name => value}, false)
      end
    end
  end
end
