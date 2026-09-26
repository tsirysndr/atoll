defmodule AtollWeb.IdentityControllerTest do
  use AtollWeb.ConnCase, async: false
  @route "/xrpc/com.atproto.identity.resolveHandle"

  setup do
    previous = Application.fetch_env(:atoll, :identity_resolution_options)

    on_exit(fn ->
      case previous do
        {:ok, opts} -> Application.put_env(:atoll, :identity_resolution_options, opts)
        :error -> Application.delete_env(:atoll, :identity_resolution_options)
      end
    end)

    :ok
  end

  test "returns a forward DNS claim without authentication", %{conn: conn} do
    Application.put_env(:atoll, :identity_resolution_options,
      txt_lookup: fn name ->
        assert name == "_atproto.alice.example.com"
        [["did=did:web:alice.example.com"]]
      end
    )

    assert conn |> get(@route, %{handle: "Alice.Example.com"}) |> json_response(200) == %{
             "did" => "did:web:alice.example.com"
           }
  end

  test "reports malformed and ambiguous handles as XRPC errors", %{conn: conn} do
    Application.put_env(:atoll, :identity_resolution_options,
      txt_lookup: fn _ ->
        [["did=did:web:alice.example.com"], ["did=did:web:bob.example.com"]]
      end
    )

    for params <- [%{}, %{handle: ["alice.example.com"]}, %{handle: "handle.invalid"}] do
      assert %{"error" => "InvalidRequest"} = conn |> get(@route, params) |> json_response(400)
    end

    assert %{"error" => "UnableToResolveHandle"} =
             conn |> get(@route, %{handle: "alice.example.com"}) |> json_response(400)
  end
end
