defmodule Atoll.DatabaseConfig do
  @moduledoc "Optional read replica configuration, independent of the primary database credentials."

  def read_replica_from_env!(env) do
    case env["READ_DATABASE_URL"] do
      nil ->
        nil

      "" ->
        nil

      url ->
        uri = URI.parse(url)

        unless uri.scheme in ["ecto", "postgres", "postgresql"] and
                 is_binary(uri.host) and uri.host != "" and
                 is_binary(uri.path) and uri.path not in ["", "/"],
               do: raise(ArgumentError, "READ_DATABASE_URL must be a PostgreSQL connection URL")

        pool_size =
          case Integer.parse(env["READ_POOL_SIZE"] || env["POOL_SIZE"] || "10") do
            {size, ""} when size > 0 -> size
            _ -> raise ArgumentError, "READ_POOL_SIZE must be a positive integer"
          end

        [
          url: url,
          pool_size: pool_size,
          socket_options: if(env["ECTO_IPV6"] in ["true", "1"], do: [:inet6], else: [])
        ]
    end
  end
end
