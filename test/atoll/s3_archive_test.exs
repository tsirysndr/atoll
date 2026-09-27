defmodule Atoll.S3ArchiveTest do
  use ExUnit.Case, async: true
  alias Atoll.{CID, Blobs.S3Archive}
  @moduletag :tmp_dir

  test "paginated archives verify empty and binary objects with private permissions", c do
    directory = Path.join(c.tmp_dir, "archive")
    objects = objects(["", <<0, 255>>, "third"])
    assert %{count: 3} = S3Archive.backup!(directory, source(objects), 1)
    assert %{count: 3} = S3Archive.verify!(directory)
    assert Bitwise.band(File.stat!(directory).mode, 0o777) == 0o700

    for path <- ["index", "manifest.json" | Map.keys(objects) |> Enum.map(&("blobs/" <> &1))] do
      assert Bitwise.band(File.stat!(Path.join(directory, path)).mode, 0o777) == 0o600
    end

    assert_raise File.Error, fn -> S3Archive.backup!(directory, source(%{})) end
    assert %{count: 3} = S3Archive.verify!(directory)
  end

  test "an empty namespace produces a valid empty archive", c do
    directory = Path.join(c.tmp_dir, "archive")
    assert %{count: 0} = S3Archive.backup!(directory, source(%{}))
    assert %{count: 0} = S3Archive.restore!(directory, source(%{}))
  end

  test "corrupt source bytes and unknown keys fail without leaving a completed archive", c do
    for entries <- [
          objects(["original"]) |> Map.new(fn {key, _} -> {key, "corrupt"} end),
          %{"not-a-cid" => "foreign"}
        ] do
      directory = Path.join(c.tmp_dir, "archive")
      assert_raise MatchError, fn -> S3Archive.backup!(directory, source(entries)) end
      refute File.exists?(directory)
    end
  end

  test "tampering, missing blobs and symlinks are rejected before any target request", c do
    entries = objects(["original"])
    [name] = Map.keys(entries)
    target = config(fn _ -> flunk("invalid archive must not contact S3") end)

    for damage <- [:bytes, :missing, :symlink, :index, :manifest] do
      directory = Path.join(c.tmp_dir, Atom.to_string(damage))
      S3Archive.backup!(directory, source(entries))
      blob = Path.join([directory, "blobs", name])

      case damage do
        :bytes ->
          File.write!(blob, "tampered")

        :missing ->
          File.rm!(blob)

        :symlink ->
          File.rename!(blob, blob <> ".original")
          File.ln_s!(blob <> ".original", blob)

        :index ->
          File.write!(Path.join(directory, "index"), "../outside\n")

        :manifest ->
          File.write!(Path.join(directory, "manifest.json"), "{}")
      end

      assert catch_error(S3Archive.restore!(directory, target))
    end
  end

  test "restore refuses a populated target without sending a PUT", c do
    directory = Path.join(c.tmp_dir, "archive")
    entries = objects(["original"])
    S3Archive.backup!(directory, source(entries))
    assert_raise MatchError, fn -> S3Archive.restore!(directory, source(entries)) end
  end

  test "repeated listing pages are rejected instead of looping", c do
    entries = objects(["original"])

    config =
      config(fn conn ->
        if conn.query_string != "" do
          Plug.Conn.send_resp(conn, 200, listing(Map.to_list(entries), "repeated"))
        else
          Plug.Conn.send_resp(conn, 200, "original")
        end
      end)

    directory = Path.join(c.tmp_dir, "archive")
    assert_raise MatchError, fn -> S3Archive.backup!(directory, config, 1) end
    refute File.exists?(directory)
  end

  test "restore detects corrupt upload readback", c do
    directory = Path.join(c.tmp_dir, "archive")
    S3Archive.backup!(directory, source(objects(["original"])))

    target =
      config(fn conn ->
        cond do
          conn.query_string != "" -> Plug.Conn.send_resp(conn, 200, listing([], nil))
          conn.method == "PUT" -> Plug.Conn.send_resp(conn, 200, "")
          conn.method == "GET" -> Plug.Conn.send_resp(conn, 200, "corrupt")
        end
      end)

    assert_raise MatchError, fn -> S3Archive.restore!(directory, target) end
    assert %{count: 1} = S3Archive.verify!(directory)
  end

  defp objects(bytes), do: Map.new(bytes, &{CID.to_base32(CID.create(&1, :raw)), &1})

  defp source(entries) do
    config(fn conn ->
      assert conn.method == "GET"

      if conn.query_string != "" do
        params = URI.decode_query(conn.query_string)
        offset = String.to_integer(params["continuation-token"] || "0")
        limit = String.to_integer(params["max-keys"])
        page = entries |> Enum.sort() |> Enum.slice(offset, limit)

        next =
          if offset + length(page) < map_size(entries),
            do: Integer.to_string(offset + length(page))

        Plug.Conn.send_resp(conn, 200, listing(page, next))
      else
        ["bucket", "blobs", name] = conn.path_info
        Plug.Conn.send_resp(conn, 200, Map.fetch!(entries, name))
      end
    end)
  end

  defp config(plug) do
    [
      endpoint: "https://s3.example.com",
      bucket: "bucket",
      access_key_id: "test",
      secret_access_key: "test",
      request: Req.new(plug: plug)
    ]
  end

  defp listing(entries, cursor) do
    contents =
      Enum.map_join(entries, fn {name, bytes} ->
        "<Contents><Key>blobs%2F#{name}</Key><Size>#{byte_size(bytes)}</Size>" <>
          "<LastModified>2026-09-27T00:00:00Z</LastModified></Contents>"
      end)

    next = if cursor, do: "<NextContinuationToken>#{cursor}</NextContinuationToken>", else: ""

    "<ListBucketResult><EncodingType>url</EncodingType><IsTruncated>#{not is_nil(cursor)}</IsTruncated>#{contents}#{next}</ListBucketResult>"
  end
end
