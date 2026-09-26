defmodule Mix.Tasks.Atoll.Invites.Create do
  use Mix.Task
  @shortdoc "Issues a limited-use signup invitation from the local operator console"
  @moduledoc """
  Creates one invite code in the configured database and prints its JSON metadata.

      mix atoll.invites.create --uses 1
      mix atoll.invites.create --uses 5 --for-account did:plc:example

  Uses must be between 1 and 10000 (default 1). The optional owner must already
  have a local repository. Codes are bearer invitations: share the output only
  with intended invitees. This is an operator task, not a public authorization API.
  """
  @impl true
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [uses: [:integer, :keep], for_account: [:string, :keep]]
      )

    uses = Keyword.get(opts, :uses, 1)

    unless positional == [] and invalid == [] and
             length(opts) == length(Keyword.keys(opts) |> Enum.uniq()) and
             is_integer(uses) and uses in 1..10_000,
           do: Mix.raise("Usage: mix atoll.invites.create [--uses 1..10000] [--for-account DID]")

    Mix.Task.run("app.start")

    case Atoll.Accounts.Invites.create(uses, opts[:for_account]) do
      {:ok, result} -> Mix.shell().info(Jason.encode!(result))
      {:error, _} -> Mix.raise("Invite creation failed; check the use count and account.")
    end
  end
end
