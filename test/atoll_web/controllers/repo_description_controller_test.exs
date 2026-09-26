defmodule AtollWeb.RepoDescriptionControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Multikey, Repositories, SigningKey}
  @did "did:web:alice.example.com"
  @handle "alice.example.com"
  @route "/xrpc/com.atproto.repo.describeRepo"

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
    {:ok, public} = Multikey.encode(key.curve, key.public)

    doc = %{
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

    configure(doc)
    %{doc: doc, key: key}
  end

  test "describes an empty repo by DID or verified handle", %{conn: conn, doc: doc} do
    expected = %{
      "did" => @did,
      "didDoc" => doc,
      "handle" => @handle,
      "handleIsCorrect" => true,
      "collections" => []
    }

    for identifier <- [@did, "Alice.Example.Com"] do
      assert conn |> get(@route, %{repo: identifier}) |> json_response(200) == expected
    end
  end

  test "lists distinct current collections and removes emptied collections", %{
    conn: conn,
    key: key
  } do
    writes =
      for {collection, rkey} <- [
            {"com.example.z", "one"},
            {"com.example.a", "one"},
            {"com.example.a", "two"}
          ],
          do: {:put, collection <> "/" <> rkey, %{"$type" => collection}}

    {:ok, _} = Repositories.apply_writes(@did, writes, key)
    {:ok, _} = Repositories.create("did:web:other.example.com", key)

    {:ok, _} =
      Repositories.apply_writes(
        "did:web:other.example.com",
        [{:put, "com.example.foreign/self", %{"$type" => "com.example.foreign"}}],
        key
      )

    assert %{"collections" => ["com.example.a", "com.example.z"]} =
             conn |> get(@route, %{repo: @did}) |> json_response(200)

    {:ok, _} = Repositories.apply_writes(@did, [{:delete, "com.example.z/one"}], key)

    assert %{"collections" => ["com.example.a"]} =
             conn |> get(@route, %{repo: @did}) |> json_response(200)
  end

  test "marks absent or nonreciprocal handles invalid for DID requests", %{conn: conn, doc: doc} do
    for aliases <- [[], ["at://other.example.com"]] do
      configure(%{doc | "alsoKnownAs" => aliases}, fn name ->
        if name == "_atproto." <> @handle,
          do: [["did=" <> @did]],
          else: [["did=did:web:elsewhere.example.com"]]
      end)

      assert %{"handle" => "handle.invalid", "handleIsCorrect" => false} =
               conn |> get(@route, %{repo: @did}) |> json_response(200)

      assert %{"error" => "InvalidRequest"} =
               conn |> get(@route, %{repo: @handle}) |> json_response(400)
    end
  end

  test "rejects malformed requests and avoids network work for absent local repos", %{conn: conn} do
    Application.put_env(:atoll, :identity_resolution_options,
      lookup: fn _ -> flunk("unexpected network request") end
    )

    for params <- [%{}, %{repo: [@did]}, %{repo: "bad"}] do
      assert %{"error" => "InvalidRequest"} = conn |> get(@route, params) |> json_response(400)
    end

    assert %{"error" => "RepoNotFound"} =
             conn |> get(@route, %{repo: "did:web:missing.example.com"}) |> json_response(400)
  end

  test "does not fabricate a DID document when resolution fails", %{conn: conn, doc: doc} do
    configure(%{doc | "id" => "did:web:other.example.com"})

    assert %{"error" => "InvalidRequest"} =
             conn |> get(@route, %{repo: @did}) |> json_response(400)
  end

  defp configure(doc, txt \\ fn _ -> [["did=" <> @did]] end) do
    Application.put_env(:atoll, :identity_resolution_options,
      txt_lookup: txt,
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
      request: Req.new(plug: fn conn -> Req.Test.json(conn, doc) end)
    )
  end
end
