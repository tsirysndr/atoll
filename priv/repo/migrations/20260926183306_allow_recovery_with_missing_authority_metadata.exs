defmodule Atoll.Repo.Migrations.AllowRecoveryWithMissingAuthorityMetadata do
  use Ecto.Migration

  def up do
    drop constraint(:plc_updates, :pending_authority_key_shape)
    create constraint(:plc_updates, :pending_authority_key_shape, check: shape(true))
  end

  def down do
    drop constraint(:plc_updates, :pending_authority_key_shape)
    create constraint(:plc_updates, :pending_authority_key_shape, check: shape(false))
  end

  defp shape(recovery?) do
    expected =
      if recovery?,
        do: "(expected_authority_key IS NOT NULL OR recovery_expected_head IS NOT NULL)",
        else: "expected_authority_key IS NOT NULL"

    "(authority_curve IS NULL AND authority_public_key IS NULL AND expected_authority_key IS NULL AND authority_envelope IS NULL) OR " <>
      "(authority_curve IS NOT NULL AND authority_curve IN ('k256', 'p256') AND authority_public_key IS NOT NULL AND octet_length(authority_public_key) = 33 AND " <>
      expected <> " AND (authority_envelope IS NULL OR octet_length(authority_envelope) = 61))"
  end
end
