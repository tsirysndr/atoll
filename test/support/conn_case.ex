defmodule AtollWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, tests that do not mutate repositories can run asynchronously
  with `use AtollWeb.ConnCase, async: true`. Tests creating or updating
  repositories must use `async: false`: their sandbox transaction holds the
  global event advisory lock until cleanup.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint AtollWeb.Endpoint

      use AtollWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import AtollWeb.ConnCase
    end
  end

  setup tags do
    Atoll.DataCase.setup_sandbox(tags)
    # Budgets are keyed by caller address, which every test shares.
    Atoll.Accounts.SessionLimiter.reset()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
