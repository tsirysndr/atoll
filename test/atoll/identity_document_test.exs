defmodule Atoll.IdentityDocumentTest do
  use ExUnit.Case, async: true
  alias Atoll.Identity.Document
  alias Atoll.{Multikey, SigningKey}
  @did "did:web:alice.example.com"

  setup do
    key = SigningKey.generate()
    {:ok, text} = Multikey.encode(key.curve, key.public)

    method = %{
      "id" => "#atproto",
      "type" => "Multikey",
      "controller" => @did,
      "publicKeyMultibase" => text
    }

    service = %{
      "id" => "#atproto_pds",
      "type" => "AtprotoPersonalDataServer",
      "serviceEndpoint" => "https://pds.example.com"
    }

    doc = %{
      "id" => @did,
      "verificationMethod" => [method],
      "service" => [service],
      "alsoKnownAs" => ["at://Alice.Example.com"]
    }

    %{doc: doc, key: key, method: method, service: service}
  end

  test "extracts modern keys, service and an explicitly unverified handle claim", %{
    doc: doc,
    key: key
  } do
    assert Document.parse(doc, @did) ==
             {:ok,
              %{
                did: @did,
                signing_key: %{curve: key.curve, public: key.public},
                pds: "https://pds.example.com",
                claimed_handle: "alice.example.com"
              }}

    assert {:ok, %{claimed_handle: nil}} = Document.parse(Map.delete(doc, "alsoKnownAs"), @did)
    assert Document.parse(doc, "did:web:other.example.com") == {:error, :invalid_did_document}
  end

  test "accepts fully qualified IDs and skips invalid keys before the first valid one", %{
    doc: doc,
    method: method,
    service: service
  } do
    bad = %{method | "controller" => "did:plc:other"}
    good = %{method | "id" => @did <> "#atproto"}
    service = %{service | "id" => @did <> "#atproto_pds"}

    doc = %{
      doc
      | "verificationMethod" => [nil, bad, %{method | "publicKeyMultibase" => "bad"}, good],
        "service" => [service],
        "alsoKnownAs" => [
          "https://example.com",
          "at://invalid",
          "at://first.example.com",
          "at://second.example.com"
        ]
    }

    assert {:ok, %{claimed_handle: "first.example.com"}} = Document.parse(doc, @did)
  end

  test "rejects unrelated IDs and malformed document fields", %{doc: doc, method: method} do
    for changed <- [
          nil,
          %{},
          Map.put(doc, "service", nil),
          Map.put(doc, "alsoKnownAs", %{}),
          Map.put(doc, "verificationMethod", []),
          Map.put(doc, "verificationMethod", [%{method | "id" => "did:plc:other#atproto"}]),
          Map.put(doc, "verificationMethod", [%{method | "type" => "unsupported"}])
        ] do
      assert Document.parse(changed, @did) == {:error, :invalid_did_document}
    end
  end

  test "rejects unsafe endpoint shapes and does not skip the first matching service", %{
    doc: doc,
    service: service
  } do
    for endpoint <- [
          nil,
          [],
          "http://pds.example.com",
          "https://user:pass@pds.example.com",
          "https://pds.example.com/path",
          "https://pds.example.com?query",
          "https://pds.example.com#fragment",
          "https://pds.example.com:99999"
        ] do
      changed = %{doc | "service" => [%{service | "serviceEndpoint" => endpoint}, service]}
      assert Document.parse(changed, @did) == {:error, :invalid_did_document}
    end
  end
end
