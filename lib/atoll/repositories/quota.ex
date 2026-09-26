defmodule Atoll.Repositories.Quota do
  @moduledoc "Per-account quotas over distinct stored blocks in retained repository history."
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Repositories.Revision
  alias Atoll.Storage.Block

  @doc "Internal inventory; callers needing a stable snapshot must hold the account lock."
  def usage(did) do
    retained =
      from r in Revision,
        where: r.did == ^did,
        distinct: true,
        select: %{cid: fragment("unnest(?)", r.blocks)}

    {count, bytes} =
      Repo.one(
        from b in Block,
          join: r in subquery(retained),
          on: r.cid == b.cid,
          select:
            {count(b.cid), type(coalesce(sum(fragment("octet_length(?)", b.data)), 0), :integer)}
      )

    %{count: count, bytes: bytes}
  end

  @doc false
  def check!(did) do
    limits = Application.get_env(:atoll, :repository_quota, [])
    bytes = Keyword.get(limits, :max_bytes, 1_073_741_824)
    count = Keyword.get(limits, :max_count, 1_000_000)

    unless is_integer(bytes) and bytes >= 0 and is_integer(count) and count >= 0,
      do: Repo.rollback(:invalid_repository_quota)

    used = usage(did)
    if used.bytes > bytes or used.count > count, do: Repo.rollback(:repository_quota_exceeded)
    :ok
  end
end
