defmodule Atoll.IdentityUpdatesTest do
  use Atoll.DataCase, async: true
  alias Atoll.{Multikey, Repositories, SigningKey}
  alias Atoll.Identity.{Observation, Updates}
  alias Atoll.Repositories.{EventEncoder, Events}
  @did "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
  @handle "alice.example.com"

  setup do
    key = SigningKey.generate()
    {:ok, head} = Repositories.create(@did, key)
    %{key: key, head: head, doc: document(key), cursor: Events.latest_seq()}
  end

  test "publishes verified identity once and replays a stable identity frame", %{
    doc: doc,
    cursor: cursor
  } do
    assert Updates.refresh(@did, options(doc)) == {:ok, :published}
    assert Updates.refresh(@did, options(doc)) == {:ok, :unchanged}
    assert {:ok, [event]} = Events.list_after(cursor)
    assert event.kind == :identity
    assert event.payload == %{"handle" => @handle}
    assert {:ok, "#identity", body} = EventEncoder.message(event)

    assert body == %{
             "did" => @did,
             "handle" => @handle,
             "seq" => event.seq,
             "time" => DateTime.to_iso8601(event.time)
           }

    assert {:ok, frame} = EventEncoder.encode(event)
    assert {:ok, {:frame, seq, ^frame}} = Events.next_frame(cursor)
    assert seq == event.seq
    assert Repo.get!(Observation, @did).handle == @handle
  end

  test "unverified or absent handles publish handle.invalid and can recover", %{
    doc: doc,
    cursor: cursor
  } do
    bad = Keyword.put(options(doc), :txt_lookup, fn _ -> [["did=did:web:other.example.com"]] end)
    assert Updates.refresh(@did, bad) == {:ok, :published}
    assert {:ok, [invalid]} = Events.list_after(cursor)
    assert invalid.payload == %{"handle" => "handle.invalid"}
    assert Updates.refresh(@did, options(doc)) == {:ok, :published}
    assert Updates.refresh(@did, options(Map.put(doc, "alsoKnownAs", []))) == {:ok, :published}
    assert Repo.get!(Observation, @did).handle == "handle.invalid"
  end

  test "key and endpoint changes emit events without changing the pinned repository key", %{
    doc: doc,
    head: head
  } do
    assert Updates.refresh(@did, options(doc)) == {:ok, :published}
    changed = document(SigningKey.generate())
    assert Updates.refresh(@did, options(changed)) == {:ok, :published}

    changed =
      put_in(changed, ["service", Access.at(0), "serviceEndpoint"], "https://other.example.com")

    assert Updates.refresh(@did, options(changed)) == {:ok, :published}
    assert Repositories.get_head(@did) == {:ok, head}
    irrelevant = Map.put(changed, "irrelevant", "metadata")
    assert Updates.refresh(@did, options(irrelevant)) == {:ok, :unchanged}
  end

  test "failed DID lookup preserves observation and emits nothing", %{doc: doc} do
    assert Updates.refresh(@did, options(doc)) == {:ok, :published}
    before = Repo.get!(Observation, @did)
    seq = Events.latest_seq()

    opts =
      Keyword.put(
        options(doc),
        :request,
        Req.new(plug: fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)
      )

    assert {:error, _} = Updates.refresh(@did, opts)
    assert Repo.get!(Observation, @did) == before
    assert Events.latest_seq() == seq

    assert Updates.refresh("did:web:missing.example.com",
             lookup: fn _ -> flunk("must not resolve unhosted DID") end
           ) == {:error, :not_found}
  end

  test "observation and event roll back together", %{doc: doc, cursor: cursor} do
    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert Updates.refresh(@did, options(doc)) == {:ok, :published}
               Repo.rollback(:abort)
             end)

    assert Repo.get(Observation, @did) == nil
    assert Events.latest_seq() == cursor
  end

  test "a stale network response cannot overwrite an intervening observation", %{
    doc: doc,
    cursor: cursor
  } do
    newer = put_in(doc, ["service", Access.at(0), "serviceEndpoint"], "https://new.example.com")

    request =
      Req.new(
        plug: fn conn ->
          assert Updates.refresh(@did, options(newer)) == {:ok, :published}
          Req.Test.json(conn, doc)
        end
      )

    assert Updates.refresh(@did, Keyword.put(options(doc), :request, request)) ==
             {:error, :stale_identity_refresh}

    assert Updates.refresh(@did, options(newer)) == {:ok, :unchanged}
    assert {:ok, [_]} = Events.list_after(cursor)
  end

  test "identity signals remain deliverable for inactive repositories", %{doc: doc} do
    {:ok, _} = Repositories.set_status(@did, :deactivated)
    cursor = Events.latest_seq()
    assert Updates.refresh(@did, options(doc)) == {:ok, :published}
    assert {:ok, {:frame, _, _}} = Events.next_frame(cursor)
  end

  defp options(doc) do
    [
      request: Req.new(plug: fn conn -> Req.Test.json(conn, doc) end),
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
      txt_lookup: fn _ -> [["did=" <> @did]] end
    ]
  end

  defp document(key) do
    {:ok, multikey} = Multikey.encode(key.curve, key.public)

    %{
      "id" => @did,
      "alsoKnownAs" => ["at://" <> @handle],
      "verificationMethod" => [
        %{
          "id" => "#atproto",
          "controller" => @did,
          "type" => "Multikey",
          "publicKeyMultibase" => multikey
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
  end
end
