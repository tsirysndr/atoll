defmodule Atoll.ServerConfigTest do
  use ExUnit.Case, async: true
  alias Atoll.ServerConfig

  test "development preserves configured metadata when no overrides are supplied" do
    assert ServerConfig.parse!(%{}, false) == %{pds: [], host: nil}
  end

  test "production requires explicit identity and hostname with empty domain default" do
    assert_raise RuntimeError, ~r/ATOLL_PDS_DID is required/, fn ->
      ServerConfig.parse!(%{}, true)
    end

    assert_raise RuntimeError, ~r/PHX_HOST is required/, fn ->
      ServerConfig.parse!(%{"ATOLL_PDS_DID" => "did:web:pds.example.com"}, true)
    end

    assert %{host: "pds.example.com", pds: pds} =
             ServerConfig.parse!(
               %{"ATOLL_PDS_DID" => "did:web:pds.example.com", "PHX_HOST" => "PDS.Example.com"},
               true
             )

    assert pds[:did] == "did:web:pds.example.com"
    assert pds[:available_user_domains] == []
  end

  test "normalizes and deduplicates advertised suffixes and supports clearing them" do
    assert ServerConfig.parse!(
             %{"ATOLL_AVAILABLE_USER_DOMAINS" => " .Example.com, .other.org,.example.com "},
             false
           ).pds == [available_user_domains: [".example.com", ".other.org"]]

    assert ServerConfig.parse!(%{"ATOLL_AVAILABLE_USER_DOMAINS" => ""}, false).pds == [
             available_user_domains: []
           ]
  end

  test "rejects malformed metadata and URL-shaped hosts without reflecting values" do
    for did <- ["", "https://pds.example.com", "did:web:", "did:web:foo\n"] do
      assert_raise RuntimeError, "ATOLL_PDS_DID must be a valid DID", fn ->
        ServerConfig.parse!(%{"ATOLL_PDS_DID" => did}, false)
      end
    end

    for host <- [
          "",
          "localhost",
          "https://pds.example.com",
          "pds.example.com:443",
          "pds.example.com/path",
          "pds.example.com\n"
        ] do
      assert_raise RuntimeError, ~r/PHX_HOST must be/, fn ->
        ServerConfig.parse!(%{"PHX_HOST" => host}, false)
      end
    end

    for domains <- [
          "example.com",
          ".localhost",
          ".example.com,",
          "https://example.com",
          ".example.com/path"
        ] do
      assert_raise RuntimeError, ~r/ATOLL_AVAILABLE_USER_DOMAINS must contain/, fn ->
        ServerConfig.parse!(%{"ATOLL_AVAILABLE_USER_DOMAINS" => domains}, false)
      end
    end
  end
end
