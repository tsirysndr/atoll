defmodule Atoll.Identity.PLC.SignupKeyRetirement do
  @moduledoc "Explicit operator erasure of superseded signup custody; signed genesis is retained."
  import Ecto.Query
  alias Atoll.{KeyVault, Multikey, Repo}
  alias Atoll.Identity.PLC.{Registration, RotationKey, RotationKeys, Update}
  alias Atoll.Repositories.{Events, Head}

  def retire(did, expected_genesis, expected_installed) do
    Repo.transaction(fn ->
      Events.lock!()

      head =
        Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
          Repo.rollback(:account_not_found)

      unless head.status in [:active, :deactivated], do: Repo.rollback(:repo_inactive)
      row = Repo.get(Registration, did, log: false) || Repo.rollback(:registration_not_found)

      unless row.cid == expected_genesis && row.completed_at,
        do: Repo.rollback(:signup_retirement_conflict)

      if Repo.exists?(from u in Update, where: u.did == ^did and is_nil(u.completed_at)),
        do: Repo.rollback(:plc_update_pending)

      installed = Repo.get(RotationKey, did, log: false) || Repo.rollback(:key_not_found)
      key = unwrap!(RotationKeys.fetch(did))
      public = unwrap!(Multikey.to_did_key(key.curve, key.public))
      unless public == expected_installed, do: Repo.rollback(:stale_rotation_key)
      unwrap!(KeyVault.fetch(did))

      update =
        Repo.get_by(Update, did: did, cid: installed.verified_cid) ||
          Repo.rollback(:plc_update_not_found)

      unless update.completed_at && update.confirmed_at &&
               public in Map.get(update.operation, "rotationKeys", []),
             do: Repo.rollback(:plc_update_unconfirmed)

      result = if row.rotation_retired_at, do: :already_retired, else: :retired

      unless row.rotation_retired_at do
        row
        |> Ecto.Changeset.change(rotation_envelope: nil, rotation_retired_at: DateTime.utc_now())
        |> Repo.update!(log: false)

        Atoll.Moderation.Audit.signup_key_retirement!(row, installed)
      end

      %{did: did, genesis_cid: row.cid, installed_key: public, result: result}
    end)
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
end
