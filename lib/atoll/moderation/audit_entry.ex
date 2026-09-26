defmodule Atoll.Moderation.AuditEntry do
  @moduledoc "Private operator decision history, retained independently of accounts."
  use Ecto.Schema

  schema "moderation_audit_entries" do
    field :did, :string
    field :subject, :map
    field :actor, :string
    field :operation, :string
    field :requested, :map, redact: true
    field :before_state, :map, redact: true
    field :after_state, :map, redact: true
    field :time, :utc_datetime_usec
  end
end
