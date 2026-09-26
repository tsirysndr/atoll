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

  defp expire,
    do:
      Repo.query!(
        "UPDATE identity_refresh_leases SET leased_until = clock_timestamp() - interval '1 second', next_attempt_at = clock_timestamp() - interval '1 second'"
      )
end
