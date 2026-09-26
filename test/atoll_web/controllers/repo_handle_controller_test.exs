defmodule AtollWeb.RepoHandleControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Multikey, Repositories, SigningKey}
  @did "did:web:alice.example.com"
  @handle "alice.example.com"
  @collection "com.example.record"
  @get "/xrpc/com.atproto.repo.getRecord"
  @list "/xrpc/com.atproto.repo.listRecords"

  setup do
    previous = Application.fetch_env(:atoll, :identity_resolution_options)

    on_exit(fn ->
      case previous do
        {:ok, opts} -> Application.put_env(:atoll, :identity_resolution_options, opts)
        :error -> Application.delete_env(:atoll, :identity_resolution_options)
      end
    end)

    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)

    {:ok, _} =
      Repositories.apply_writes(
        @did,
        for(
          rkey <- ["a", "b", "c"],
          do: {:put, @collection <> "/" <> rkey, %{"$type" => @collection, "text" => rkey}}
        ),
        key
      )

    {:ok, public} = Multikey.encode(key.curve, key.public)

    document = %{
      "id" => @did,
      "alsoKnownAs" => ["at://" <> @handle],
      "verificationMethod" => [
        %{
          "id" => "#atproto",
          "controller" => @did,
          "type" => "Multikey",
          "publicKeyMultibase" => public
        }
      ],
      "service" => [
        %{
          "id" => "#atproto_pds",
          "type" => "AtprotoPersonalDataServer",
          "serviceEndpoint" => "https://pds.example.com"
        }
      ]
    }

    configure(document)
    %{document: document}
  end

  test "handle and DID reads return identical records and canonical DID URIs", %{conn: conn} do
    params = %{repo: @did, collection: @collection, rkey: "a"}
    expected = conn |> get(@get, params) |> json_response(200)

    assert conn |> get(@get, %{params | repo: "Alice.Example.Com"}) |> json_response(200) ==
             expected

    assert expected["uri"] == "at://#{@did}/#{@collection}/a"

    assert conn
           |> get(@get, Map.put(%{params | repo: @handle}, :cid, expected["cid"]))
           |> json_response(200) == expected
  end

  test "handle listing preserves cursor and reverse behavior", %{conn: conn} do
    params = %{repo: @handle, collection: @collection, limit: "2", reverse: "true"}
    page = conn |> get(@list, params) |> json_response(200)
    assert Enum.map(page["records"], & &1["value"]["text"]) == ["a", "b"]
    next = conn |> get(@list, Map.put(params, :cursor, page["cursor"])) |> json_response(200)
    assert Enum.map(next["records"], & &1["value"]["text"]) == ["c"]
  end

  test "rejects a forward-only alias and a conflicting document identity", %{
    conn: conn,
    document: document
  } do
    for doc <- [
          %{document | "alsoKnownAs" => ["at://other.example.com"]},
          %{document | "id" => "did:web:other.example.com"}
        ] do
      configure(doc)

      for route <- [@get, @list] do
        assert %{"error" => "InvalidRequest"} =
                 conn
                 |> get(route, %{repo: @handle, collection: @collection, rkey: "a"})
                 |> json_response(400)
      end
    end
  end

  test "validates query arguments before making network requests and bypasses resolution for DIDs",
       %{conn: conn} do
    Application.put_env(:atoll, :identity_resolution_options,
      txt_lookup: fn _ -> flunk("unexpected DNS lookup") end
    )

    assert %{"error" => "InvalidRequest"} =
             conn
             |> get(@get, %{repo: @handle, collection: @collection, rkey: "a", cid: "bad"})
             |> json_response(400)

    assert %{"error" => "InvalidRequest"} =
             conn
             |> get(@list, %{repo: @handle, collection: @collection, limit: "0"})
             |> json_response(400)

    assert %{"value" => _} =
             conn
             |> get(@get, %{repo: @did, collection: @collection, rkey: "a"})
             |> json_response(200)
  end

  defp configure(document) do
    Application.put_env(:atoll, :identity_resolution_options,
      txt_lookup: fn _ -> [["did=" <> @did]] end,
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
      request: Req.new(plug: fn conn -> Req.Test.json(conn, document) end)
    )
  end
end
