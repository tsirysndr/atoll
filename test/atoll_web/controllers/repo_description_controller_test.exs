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

  test "streams the complete collection list across cursor and JSON chunk boundaries", c do
    names = seed_collections(c.key, 300)
    doc = Map.put(c.doc, "extra", "quoted \"value\"\nwith a newline")
    configure(doc)
    reply = get(c.conn, @route, %{repo: @did})
    assert reply.state == :chunked
    assert get_resp_header(reply, "cache-control") == ["no-store"]
    assert %{"collections" => ^names, "didDoc" => ^doc} = json_response(reply, 200)
  end

  test "buffered inventories have exact budgets while streaming consumers may stop early", c do
    names = seed_collections(c.key, 300)
    bytes = Enum.sum(Enum.map(names, &(byte_size(&1) + 64)))
    assert {:ok, ^names} = Repositories.collections(@did, max_bytes: bytes)

    assert {:error, :repository_metadata_too_large} =
             Repositories.collections(@did, max_bytes: bytes - 1)

    assert {:ok, [first]} =
             Repositories.stream_collections(@did, fn stream ->
               assert Atoll.Repo.in_transaction?()
               refute is_list(stream)
               Enum.take(stream, 1)
             end)

    assert first == hd(names)
    refute Atoll.Repo.in_transaction?()
    opts = Application.fetch_env!(:atoll, :identity_resolution_options)

    assert {:error, :repository_metadata_too_large} =
             Atoll.Repositories.Description.get(@did, Keyword.put(opts, :max_collection_bytes, 1))

    for limit <- [0, -1, nil, "64"] do
      assert_raise ArgumentError, fn -> Repositories.collections(@did, max_bytes: limit) end
    end
  end

  test "resolves identity outside the collection transaction and rechecks availability before streaming",
       c do
    opts = Application.fetch_env!(:atoll, :identity_resolution_options)

    request =
      Req.new(
        plug: fn conn ->
          refute Atoll.Repo.in_transaction?()
          {:ok, _} = Repositories.set_status(@did, :deactivated)
          Req.Test.json(conn, c.doc)
        end
      )

    Application.put_env(
      :atoll,
      :identity_resolution_options,
      Keyword.put(opts, :request, request)
    )

    reply = get(c.conn, @route, %{repo: @did})
    refute reply.state == :chunked
    assert %{"error" => "RepoDeactivated"} = json_response(reply, 400)
  end

  defp seed_collections(key, count) do
    names = Enum.map(1..count, &"com.example.c#{&1}") |> Enum.sort()

    names
    |> Enum.map(&{:put, &1 <> "/self", %{"$type" => &1}})
    |> Enum.chunk_every(200)
    |> Enum.each(fn writes -> assert {:ok, _} = Repositories.apply_writes(@did, writes, key) end)

    names
  end

  defp configure(doc, txt \\ fn _ -> [["did=" <> @did]] end) do
    Application.put_env(:atoll, :identity_resolution_options,
      txt_lookup: txt,
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
      request: Req.new(plug: fn conn -> Req.Test.json(conn, doc) end)
    )
  end
end
