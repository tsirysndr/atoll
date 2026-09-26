defmodule Atoll.RevisionSigningKeyTest do
  use Atoll.DataCase, async: true
  alias Atoll.{CAR, Repo, Repositories, SigningKey}
  alias Atoll.Repositories.{Events, Head, Record, Revision}
  @did "did:plc:revisionkeys"
  @path "com.example.record/one"

  test "retained revisions verify with their original keys after a cross-curve transition" do
    old = SigningKey.generate(:k256)
    new = SigningKey.generate(:p256)
    {:ok, _} = Repositories.create(@did, old)

    {:ok, previous} =
      Repositories.apply_writes(
        @did,
        [{:put, @path, %{"$type" => "com.example.record", "text" => "old"}}],
        old
      )

    old_record = Repo.get_by!(Record, did: @did, path: @path).cid
    # Model a future atomic key transition; this is not a public rotation workflow.
    {:ok, current} =
      Repo.transaction(fn ->
        Events.lock!()

        Repo.get!(Head, @did)
        |> Ecto.Changeset.change(curve: new.curve, public_key: new.public)
        |> Repo.update!()

        {:ok, head} =
          Repositories.apply_writes(
            @did,
            [{:put, @path, %{"$type" => "com.example.record", "text" => "new"}}],
            new
          )

        head
      end)

    prior_revision = Repo.get_by!(Revision, did: @did, rev: previous.rev)
    current_revision = Repo.get_by!(Revision, did: @did, rev: current.rev)
    assert prior_revision.signing_curve == old.curve
    assert prior_revision.signing_public_key == old.public
    assert current_revision.signing_curve == new.curve
    assert current_revision.signing_public_key == new.public
    assert {:ok, %{value: %{"text" => "old"}}} = Repositories.get_record(@did, @path, old_record)
    assert {:ok, archive} = Repositories.export_blocks(@did, [old_record, previous.head])
    assert {:ok, %{blocks: blocks}} = CAR.decode(archive)
    assert Map.has_key?(blocks, old_record)
    assert Map.has_key?(blocks, previous.head)

    Repo.update_all(from(r in Revision, where: r.did == @did and r.rev == ^previous.rev),
      set: [signing_public_key: new.public]
    )

    assert {:error, :invalid_repository} = Repositories.get_record(@did, @path, old_record)
  end
end
