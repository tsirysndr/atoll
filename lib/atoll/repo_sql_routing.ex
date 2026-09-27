defmodule Atoll.RepoSQLRouting do
  @moduledoc false

  # The SQL adapter adds these functions in its own before_compile callback.
  # Register after the adapter so raw writes obey the same primary affinity as
  # Ecto writes, without attempting to parse arbitrary SQL.
  defmacro __before_compile__(_env) do
    for name <- [:query, :query!, :query_many, :query_many!] do
      quote do
        defoverridable [{unquote(name), 3}]

        def unquote(name)(sql, params, opts) do
          pin_primary!()
          super(sql, params, opts)
        end
      end
    end
  end
end
