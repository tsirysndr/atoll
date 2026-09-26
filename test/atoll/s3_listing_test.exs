defmodule Atoll.S3ListingTest do
  use ExUnit.Case, async: true
  alias Atoll.Blobs.{S3, S3Listing}

  test "parses URL-encoded keys and XML-escaped opaque continuation tokens" do
    xml =
      listing(
        "<Contents><Key>blobs%2Fa%2Bb%26c</Key><Size>12</Size><LastModified>2026-09-26T10:00:00.000Z</LastModified></Contents>",
        true,
        "next&amp;token+opaque"
      )

    assert {:ok, %{objects: [%{key: "blobs/a+b&c", size: 12}], cursor: "next&token+opaque"}} =
             S3Listing.parse(xml, 1)
  end

  test "rejects malicious, malformed, oversized, inconsistent and over-limit listings" do
    item =
      "<Contents><Key>blobs%2Fkey</Key><Size>0</Size><LastModified>2026-09-26T10:00:00Z</LastModified></Contents>"

    for xml <- [
          "<!DOCTYPE x SYSTEM 'file:///etc/passwd'><x/>",
          "<broken>",
          listing(item <> item),
          listing(item) <> "junk",
          listing(item, true),
          listing(item) |> String.replace("<Size>0", "<Size>-1"),
          listing(item) |> String.replace("blobs%2F", "outside%2F"),
          listing(item) |> String.replace("blobs%2F", "blobs%xx"),
          listing(item)
          |> String.replace(
            "<IsTruncated>false</IsTruncated>",
            "<IsTruncated>false</IsTruncated><IsTruncated>false</IsTruncated>"
          ),
          String.duplicate("x", 5 * 1024 * 1024 + 1)
        ] do
      assert {:error, :invalid_s3_listing} = S3Listing.parse(xml, 1)
    end

    assert {:error, :invalid_s3_listing} = S3Listing.parse(listing(item), 0)
  end

  test "signs a single bounded listing request with encoded pagination and rejects redirects" do
    config = [
      endpoint: "https://s3.example.com",
      bucket: "atoll-test",
      access_key_id: "key",
      secret_access_key: "secret",
      request: Req.new(plug: {Req.Test, __MODULE__})
    ]

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/atoll-test"
      assert [auth] = Plug.Conn.get_req_header(conn, "authorization")
      assert auth =~ "AWS4-HMAC-SHA256"
      params = URI.decode_query(conn.query_string)

      assert params == %{
               "list-type" => "2",
               "prefix" => "blobs/",
               "encoding-type" => "url",
               "max-keys" => "7",
               "continuation-token" => "token+&/="
             }

      Plug.Conn.send_resp(conn, 200, listing(""))
    end)

    assert {:ok, %{objects: [], cursor: nil}} = S3.list(config, 7, "token+&/=")

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://other.example.com")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, :blob_storage_unavailable} = S3.list(config)
    assert {:error, :invalid_inventory_query} = S3.list(config, 1001)
    assert {:error, :invalid_inventory_query} = S3.list(config, 1, "bad\n")
  end

  defp listing(contents, truncated \\ false, token \\ nil) do
    "<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><EncodingType>url</EncodingType><IsTruncated>#{truncated}</IsTruncated>#{contents}#{if token, do: "<NextContinuationToken>#{token}</NextContinuationToken>", else: ""}</ListBucketResult>"
  end
end
