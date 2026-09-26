defmodule Atoll.WebKeyRotationTest do
  use Atoll.DataCase, async: false
  alias Atoll.{KeyVault, Multikey, Repo, Repositories, SigningKey}
  alias Atoll.Accounts.Profile
  alias Atoll.Identity.{Observation, WebKeyRotation}
  alias Atoll.Moderation.AuditEntry
  alias Atoll.Repositories.Events
  @did "did:web:rotate.example.com"
  @handle "rotate.example.com"

  setup do
    endpoint = Application.fetch_env!(:atoll, AtollWeb.Endpoint)

    AtollWeb.Endpoint.config_change(
      [
        {AtollWeb.Endpoint,
         Keyword.put(endpoint, :url, scheme: "https", host: "pds.example.com", port: 443)}
      ],
      []
    )

    on_exit(fn -> AtollWeb.Endpoint.config_change([{AtollWeb.Endpoint, endpoint}], []) end)

    for name <- [:key_encryption_key, :repository_quota, :identity_resolution_options] do
      previous = Application.fetch_env(:atoll, name)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:atoll, name, value)
          :error -> Application.delete_env(:atoll, name)
        end
      end)
    end

    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    old = SigningKey.generate()
    new = SigningKey.generate(:p256)
    {:ok, head} = Repositories.create(@did, old)
    {:ok, _} = KeyVault.store(@did, old)
    Repo.insert!(%Profile{did: @did, handle: @handle})
    {:ok, expected} = Multikey.to_did_key(old.curve, old.public)
    %{old: old, new: new, head: head, expected: expected}
  end

  test "fresh authority permits cross-curve rotation, ordered events and public audit", c do
    seq = Events.latest_seq()
    assert {:ok, %{result: :rotated}} = rotate(c, document(c.new))
    assert KeyVault.fetch(@did) == {:ok, c.new}
    assert {:ok, [%{kind: :identity}, %{kind: :sync}]} = Events.list_after(seq)
    assert Repo.get!(Observation, @did).handle == @handle
    audit = Repo.one!(AuditEntry)
    assert audit.actor == "operator"
    assert audit.before_state["key"] == c.expected
    {:ok, new_key} = Multikey.to_did_key(c.new.curve, c.new.public)
    assert audit.after_state["key"] == new_key
    refute inspect(audit) =~ Base.encode64(c.new.private)
    seq = Events.latest_seq()
    assert {:error, :stale_signing_key} = rotate(c, document(c.new))
    assert {:ok, %{result: :unchanged}} = rotate(%{c | expected: new_key}, document(c.new))
    assert Events.latest_seq() == seq
  end

  test "wrong document key, service, handle or forward claim cannot rotate", c do
    doc = document(c.new)

    for invalid <- [
          document(c.old),
          put_in(doc, ["alsoKnownAs"], ["at://wrong.example.com"]),
          put_in(doc, ["service", Access.at(0), "serviceEndpoint"], "https://wrong.example.com")
        ] do
      assert {:error, _} = rotate(c, invalid)
    end

    assert {:error, _} =
             WebKeyRotation.rotate(
               @did,
               c.expected,
               c.new,
               Keyword.put(options(doc), :txt_lookup, fn _ ->
                 [["did=did:web:wrong.example.com"]]
               end)
             )

    assert KeyVault.fetch(@did) == {:ok, c.old}
    assert Repositories.get_head(@did) == {:ok, c.head}
    assert Repo.aggregate(AuditEntry, :count) == 0
  end

  test "local identity change during resolution fences completion", c do
    opts =
      options(document(c.new), fn ->
        Repo.get!(Profile, @did)
        |> Ecto.Changeset.change(handle: "changed.example.com")
        |> Repo.update!()
      end)

    assert {:error, :stale_identity_refresh} =
             WebKeyRotation.rotate(@did, c.expected, c.new, opts)

    assert KeyVault.fetch(@did) == {:ok, c.old}
  end

  test "profile removal during resolution returns a stale identity error", c do
    opts = options(document(c.new), fn -> Repo.delete!(Repo.get!(Profile, @did)) end)

    assert {:error, :stale_identity_refresh} =
             WebKeyRotation.rotate(@did, c.expected, c.new, opts)

    assert KeyVault.fetch(@did) == {:ok, c.old}
  end

  test "quota failure rolls back identity event, observation, vault and audit", c do
    Application.put_env(:atoll, :repository_quota, max_bytes: 0)
    seq = Events.latest_seq()
    assert {:error, :repository_quota_exceeded} = rotate(c, document(c.new))
    assert Events.latest_seq() == seq
    assert Repo.get(Observation, @did) == nil
    assert Repo.aggregate(AuditEntry, :count) == 0
    assert KeyVault.fetch(@did) == {:ok, c.old}
    assert Repositories.get_head(@did) == {:ok, c.head}
  end

  test "operator command loads bounded private-key file and emits only public result", c do
    path = Path.join(System.tmp_dir!(), "atoll-rotate-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    File.write!(path, Jason.encode!(%{curve: "p256", privateKey: Base.encode64(c.new.private)}))
    File.chmod!(path, 0o600)
    Application.put_env(:atoll, :identity_resolution_options, options(document(c.new)))

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Keys.RotateWeb.run([@did, path, c.expected])
      end)

    assert Jason.decode!(output)["result"] == "rotated"
    refute output =~ Base.encode64(c.new.private)
    File.write!(path, String.duplicate("x", 4097))

    assert_raise Mix.Error, ~r/Invalid expected key/, fn ->
      Mix.Tasks.Atoll.Keys.RotateWeb.run([@did, path, c.expected])
    end
  end

  defp rotate(c, doc), do: WebKeyRotation.rotate(@did, c.expected, c.new, options(doc))

  defp options(doc, hook \\ fn -> :ok end) do
    [
      request:
        Req.new(
          plug: fn conn ->
            assert conn.method == "GET"
            assert conn.request_path == "/.well-known/did.json"
            hook.()
            Req.Test.json(conn, doc)
          end
        ),
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
      txt_lookup: fn _ -> [["did=" <> @did]] end
    ]
  end

  defp document(key) do
    {:ok, encoded} = Multikey.encode(key.curve, key.public)

    %{
      "id" => @did,
      "alsoKnownAs" => ["at://" <> @handle],
      "verificationMethod" => [
        %{
          "id" => "#atproto",
          "controller" => @did,
          "type" => "Multikey",
          "publicKeyMultibase" => encoded
        }
      ],
      "service" => [
        %{
          "id" => "#atproto_pds",
          "type" => "AtprotoPersonalDataServer",
          "serviceEndpoint" => AtollWeb.Endpoint.url()
        }
      ]
    }
  end
end
