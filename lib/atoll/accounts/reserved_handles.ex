defmodule Atoll.Accounts.ReservedHandles do
  @moduledoc """
  Operator-reserved first labels beneath the hosted handle domains.

  Self-service signup and handle claims reject these labels; operator
  endpoints stay unrestricted so the operator can register placeholders
  deliberately. An account already holding a reserved handle keeps it.
  """
  @default ~w(
    www admin administrator mail email smtp imap pop pds api app atproto
    cdn static assets media abuse security root postmaster hostmaster
    webmaster noreply no-reply support help info contact staff mod moderator
    moderation team official system status blog news about legal privacy
    terms billing payments
  )

  def default, do: @default

  @doc "Whether a self-service claim of this handle by this DID must be refused."
  def blocked?(handle, did \\ nil) do
    reserved?(handle) and not owned?(handle, did)
  end

  defp reserved?(handle) do
    is_binary(handle) and Atoll.Accounts.Signup.hosted_handle?(handle) and
      hd(String.split(handle, ".")) in Application.get_env(:atoll, :reserved_handles, @default)
  end

  defp owned?(_handle, nil), do: false

  defp owned?(handle, did) do
    case Atoll.Repo.get_by(Atoll.Accounts.Profile, handle: handle) do
      %{did: ^did} -> true
      _ -> false
    end
  end

  @doc false
  def list_from_env!(nil), do: @default
  def list_from_env!(""), do: []

  def list_from_env!(value) when is_binary(value) and byte_size(value) <= 8192 do
    labels =
      value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.map(&String.downcase/1)

    unless labels != [] and
             Enum.all?(labels, &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, &1)),
           do:
             raise(
               ArgumentError,
               "ATOLL_RESERVED_HANDLES must be comma-separated DNS labels, or empty to disable"
             )

    Enum.uniq(labels)
  end

  def list_from_env!(_),
    do: raise(ArgumentError, "ATOLL_RESERVED_HANDLES must be comma-separated DNS labels")
end
