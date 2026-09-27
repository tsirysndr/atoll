defmodule Atoll.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, tests that do not mutate repositories can run asynchronously
  with `use Atoll.DataCase, async: true`. Repository mutations take the global
  event advisory lock, which the sandbox retains until the test ends. Those
  test modules must use `async: false` to avoid queuing behind other tests.
  """

  use ExUnit.CaseTemplate
  require Atoll.Database

  using do
    quote do
      alias Atoll.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Atoll.DataCase
    end
  end

  setup tags do
    Atoll.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Atoll.Repo, shared: not tags[:async])

    if Atoll.Database.sqlite?() do
      # Sandbox forces BEGIN DEFERRED regardless of the repo default. Acquire
      # its writer lock before any reads so it cannot retain a stale WAL snapshot
      # across another connection's cleanup commit.
      Atoll.Repo.query!("UPDATE event_retention_state SET cursor_floor = cursor_floor WHERE 0")
    end

    Process.put({__MODULE__, :sandbox_owner}, pid)
    on_exit({__MODULE__, :sandbox}, fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  # Independent-connection tests use only values from their sandbox fixtures.
  # Roll those fixtures back before committing separate rows on SQLite, where
  # a sandbox transaction otherwise holds the database's sole writer lock.
  def independent_connections do
    if Atoll.Database.sqlite?() do
      on_exit({__MODULE__, :sandbox}, fn -> :ok end)
      Ecto.Adapters.SQL.Sandbox.stop_owner(Process.get({__MODULE__, :sandbox_owner}))
    end

    :ok
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
