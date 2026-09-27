defmodule Atoll.DatabaseConfigTest do
  use ExUnit.Case, async: true
  alias Atoll.DatabaseConfig

  test "the reader is optional and has independent connection settings" do
    assert DatabaseConfig.read_replica_from_env!(%{}) == nil
    assert DatabaseConfig.read_replica_from_env!(%{"READ_DATABASE_URL" => ""}) == nil

    url = "postgres://reader:secret@replica.example/atoll?ssl=true"

    assert DatabaseConfig.read_replica_from_env!(%{"READ_DATABASE_URL" => url}) ==
             [url: url, pool_size: 10, socket_options: []]

    config =
      DatabaseConfig.read_replica_from_env!(%{
        "READ_DATABASE_URL" => url,
        "READ_POOL_SIZE" => "3",
        "POOL_SIZE" => "20",
        "ECTO_IPV6" => "true"
      })

    assert config[:pool_size] == 3
    assert config[:socket_options] == [:inet6]

    assert DatabaseConfig.read_replica_from_env!(%{
             "READ_DATABASE_URL" => url,
             "POOL_SIZE" => "7"
           })[:pool_size] == 7
  end

  test "invalid settings fail without exposing credentials" do
    for url <- ["garbage", "https://user:secret@replica.example/db", "postgres://replica.example"] do
      error =
        assert_raise ArgumentError, fn ->
          DatabaseConfig.read_replica_from_env!(%{"READ_DATABASE_URL" => url})
        end

      refute error.message =~ "secret"
    end

    for size <- ["0", "-1", "bad", "2x"] do
      assert_raise ArgumentError, ~r/READ_POOL_SIZE/, fn ->
        DatabaseConfig.read_replica_from_env!(%{
          "READ_DATABASE_URL" => "postgres://localhost/atoll",
          "READ_POOL_SIZE" => size
        })
      end
    end
  end

  test "read pool enforces read-only sessions and shares database telemetry" do
    {:ok, config} =
      Atoll.ReadRepo.init(:supervisor,
        parameters: [application_name: "reader", default_transaction_read_only: "off"]
      )

    assert config[:parameters][:default_transaction_read_only] == "on"
    assert config[:parameters][:application_name] == "reader"
    assert config[:telemetry_prefix] == [:atoll, :repo]
    assert Application.fetch_env!(:atoll, :ecto_repos) == [Atoll.Repo]
    refute function_exported?(Atoll.ReadRepo, :insert, 2)
  end
end
