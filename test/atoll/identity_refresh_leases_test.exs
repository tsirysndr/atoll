defmodule Atoll.IdentityRefreshLeasesTest do
  use Atoll.DataCase, async: false
  alias Atoll.{Repositories, SigningKey, Multikey}
  alias Atoll.Identity.{RefreshLeases, Updates, Observation}
  alias Atoll.Repositories.Events
  @did "did:web:leased-refresh.example.com"

  setup do
    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    {:ok, multikey} = Multikey.encode(key.curve, key.public)

    doc = %{
      "id" => @did,
      "alsoKnownAs" => ["at://leased-refresh.example.com"],
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

    opts = [
      request: Req.new(plug: fn conn -> Req.Test.json(conn, doc) end),
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
      txt_lookup: fn _ -> [["did=" <> @did]] end
    ]

    %{opts: opts}
  end

  test "claims exclude other workers, completion adds a shared cooldown, and expiry permits recovery" do
    assert {:ok, token} = RefreshLeases.claim(@did)
    assert :skipped = RefreshLeases.claim(@did)
    assert :ok = RefreshLeases.complete(@did, token)
    assert :skipped = RefreshLeases.claim(@did)
    expire()
    assert {:ok, newer} = RefreshLeases.claim(@did)
    refute newer == token
    assert {:error, :stale_refresh_lease} = RefreshLeases.complete(@did, token)
    assert :skipped = RefreshLeases.claim(@did)
    assert :ok = RefreshLeases.complete(@did, newer)
  end

  test "automatic refreshes publish once and skip network while leased or cooling down", c do
    seq = Events.latest_seq()
    assert {:ok, :published} = RefreshLeases.refresh(@did, c.opts)

    assert {:ok, :skipped} =
             RefreshLeases.refresh(@did, lookup: fn _ -> flunk("cooldown must avoid network") end)

    assert {:ok, [_]} = Events.list_after(seq)
    expire()
    assert {:ok, :unchanged} = RefreshLeases.refresh(@did, c.opts)
  end

  test "expired and replaced workers cannot publish, even after successful resolution", c do
    {:ok, old} = RefreshLeases.claim(@did)
    expire()
    seq = Events.latest_seq()

    assert {:error, :stale_refresh_lease} =
             Updates.refresh(@did, Keyword.put(c.opts, :refresh_lease, old))

    {:ok, current} = RefreshLeases.claim(@did)

    assert {:error, :stale_refresh_lease} =
             Updates.refresh(@did, Keyword.put(c.opts, :refresh_lease, old))

    assert Repo.get(Observation, @did) == nil
    assert Events.latest_seq() == seq
    assert {:ok, :published} = Updates.refresh(@did, Keyword.put(c.opts, :refresh_lease, current))
  end

  test "resolution failures share cooldowns and account deletion removes coordination state" do
    assert {:error, _} = RefreshLeases.refresh(@did, lookup: fn _ -> {:error, :nxdomain} end)
    assert :skipped = RefreshLeases.claim(@did)
    Repo.query!("DELETE FROM repositories WHERE did = $1", [@did])
    assert [[0]] = Repo.query!("SELECT count(*) FROM identity_refresh_leases").rows
    assert :skipped = RefreshLeases.claim(@did)
  end

  test "database failure fails closed before resolution" do
    assert {:error, :restore} =
             Repo.transaction(fn ->
               Repo.query!(
                 "ALTER TABLE identity_refresh_leases RENAME TO unavailable_identity_refresh_leases"
               )

               assert {:error, :refresh_lease_unavailable} =
                        RefreshLeases.refresh(@did,
                          lookup: fn _ -> flunk("must not resolve without a lease") end
                        )

               Repo.rollback(:restore)
             end)
  end

  test "unchanged automatic refreshes do not acquire publication locks or commit", c do
    assert {:ok, :published} = RefreshLeases.refresh(@did, c.opts)
    expire()
    assert {:ok, token} = RefreshLeases.claim(@did)
    owner = self()
    tag = make_ref()
    handler = {__MODULE__, tag}

    :telemetry.attach(
      handler,
      [:atoll, :repo, :query],
      fn _, _, meta, _ ->
        send(owner, {tag, meta.query})
      end,
      nil
    )

    try do
      assert {:ok, :unchanged} = Updates.refresh(@did, Keyword.put(c.opts, :refresh_lease, token))
      queries = queries(tag, [])

      refute Enum.any?(queries, fn query ->
               query in ["begin", "commit"] or String.contains?(query, "advisory") or
                 String.contains?(query, "FOR UPDATE")
             end)
    after
      :telemetry.detach(handler)
    end
  end

  test "unchanged identities still reject an expired automatic lease", c do
    assert {:ok, :published} = RefreshLeases.refresh(@did, c.opts)
    expire()
    assert {:ok, token} = RefreshLeases.claim(@did)
    expire()
    seq = Events.latest_seq()

    assert {:error, :stale_refresh_lease} =
             Updates.refresh(@did, Keyword.put(c.opts, :refresh_lease, token))

    assert Events.latest_seq() == seq
  end

  @tag :postgres
  test "database publication failure returns an error and leaves no partial event", c do
    {:ok, token} = RefreshLeases.claim(@did)
    seq = Events.latest_seq()

    assert {:error, :restore} =
             Repo.transaction(fn ->
               Repo.query!("""
               CREATE FUNCTION reject_test_identity_refresh() RETURNS trigger LANGUAGE plpgsql AS $$
               BEGIN
                 RAISE EXCEPTION 'simulated identity statement timeout' USING ERRCODE = '57014';
               END;
               $$
               """)

               Repo.query!(
                 "CREATE TRIGGER reject_test_identity_refresh BEFORE INSERT ON repository_identities FOR EACH ROW EXECUTE FUNCTION reject_test_identity_refresh()"
               )

               assert {:error, :identity_refresh_unavailable} =
                        Updates.refresh(@did, Keyword.put(c.opts, :refresh_lease, token))

               Repo.rollback(:restore)
             end)

    assert Repo.get(Observation, @did) == nil
    assert Events.latest_seq() == seq
    assert {:ok, :published} = Updates.refresh(@did, Keyword.put(c.opts, :refresh_lease, token))
  end

  defp queries(tag, acc) do
    receive do
      {^tag, query} -> queries(tag, [query | acc])
    after
      0 -> acc
    end
  end

  defp expire,
    do:
      Repo.query!(
        Atoll.Database.sql(
          "UPDATE identity_refresh_leases SET leased_until = clock_timestamp() - interval '1 second', next_attempt_at = clock_timestamp() - interval '1 second'",
          "UPDATE identity_refresh_leases SET leased_until = strftime('%Y-%m-%dT%H:%M:%f000', 'now', '-1 second'), next_attempt_at = strftime('%Y-%m-%dT%H:%M:%f000', 'now', '-1 second')"
        )
      )
end
