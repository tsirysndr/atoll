defmodule Atoll.ServerRuntimeConfigTest do
  use ExUnit.Case, async: false

  setup do
    values = %{
      "ATOLL_PDS_DID" => "did:web:pds.example.com",
      "ATOLL_AVAILABLE_USER_DOMAINS" => ".example.com",
      "PHX_HOST" => "PDS.Example.com",
      "DATABASE_URL" => "ecto://postgres:postgres@localhost/atoll_config_test",
      "SECRET_KEY_BASE" => String.duplicate("a", 64)
    }

    previous = Map.new(values, fn {key, _} -> {key, System.get_env(key)} end)
    System.put_env(values)

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    :ok
  end

  test "production runtime installs metadata and normalizes the public hostname" do
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    assert config[:atoll][:pds][:did] == "did:web:pds.example.com"
    assert config[:atoll][:pds][:available_user_domains] == [".example.com"]

    assert config[:atoll][AtollWeb.Endpoint][:url] == [
             host: "pds.example.com",
             port: 443,
             scheme: "https"
           ]
  end

  test "production runtime fails before boot when server identity is missing" do
    System.delete_env("ATOLL_PDS_DID")

    assert_raise RuntimeError, "ATOLL_PDS_DID is required in production", fn ->
      Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    end
  end
end
