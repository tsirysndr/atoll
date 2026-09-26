defmodule Atoll.Lexicon.LoaderTest do
  use ExUnit.Case, async: false
  alias Atoll.Lexicon.{Loader, Schema}
  @id "com.example.custom"

  setup do
    dir = Path.join(System.tmp_dir!(), "atoll-lexicons-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.fetch_env(:atoll, :record_lexicons)

    on_exit(fn ->
      File.rm_rf!(dir)

      case previous do
        {:ok, value} -> Application.put_env(:atoll, :record_lexicons, value)
        :error -> Application.delete_env(:atoll, :record_lexicons)
      end
    end)

    %{dir: dir}
  end

  test "loads a local catalog and validates constants, enums, bytes, links and references", %{
    dir: dir
  } do
    doc =
      document(%{
        "version" => %{"type" => "integer", "const" => 1},
        "kind" => %{"type" => "string", "enum" => ["note", "entry"]},
        "bytes" => %{"type" => "bytes", "maxLength" => 3},
        "link" => %{"type" => "cid-link"},
        "subject" => %{"type" => "ref", "ref" => "com.atproto.repo.strongRef"},
        "details" => %{"type" => "ref", "ref" => "com.example.defs#details"}
      })

    helper = %{
      "lexicon" => 1,
      "id" => "com.example.defs",
      "defs" => %{
        "details" => %{
          "type" => "object",
          "required" => ["enabled"],
          "properties" => %{"enabled" => %{"type" => "boolean", "const" => true}}
        }
      }
    }

    write!(dir, "record", doc)
    write!(dir, "defs", helper)
    custom = Loader.load!(dir)
    Application.put_env(:atoll, :record_lexicons, custom)
    cid = Atoll.CID.create("subject", :dag_cbor) |> Atoll.CID.to_base32()

    record = %{
      "$type" => @id,
      "version" => 1,
      "kind" => "note",
      "bytes" => %{"$bytes" => "YWJj"},
      "link" => %{"$link" => cid},
      "subject" => %{"uri" => "at://did:plc:test/com.example.record/one", "cid" => cid},
      "details" => %{"enabled" => true}
    }

    assert {:ok, "valid"} = Schema.record(@id, "one", record, true)
    assert {:ok, "valid"} = Schema.record(@id, "one", record, :optimistic)

    for changes <- [
          %{"version" => 2},
          %{"kind" => "other"},
          %{"bytes" => %{"$bytes" => "YWJjZA=="}},
          %{"link" => %{"$link" => "bad"}},
          %{"details" => %{"enabled" => false}}
        ] do
      assert {:error, :invalid_record_schema} =
               Schema.record(@id, "one", Map.merge(record, changes), true)
    end

    assert {:ok, "unknown"} = Schema.record(@id, "one", %{}, false)
  end

  test "rejects duplicate keys, overrides, missing references and unsupported constraints", %{
    dir: dir
  } do
    File.write!(Path.join(dir, "bad.json"), ~s({"lexicon":1,"lexicon":1}))
    assert_raise ArgumentError, ~r/duplicate JSON/, fn -> Loader.load!(dir) end
    assert_raise ArgumentError, fn -> Loader.validate!([document(%{}), document(%{})]) end

    assert_raise ArgumentError, fn ->
      Loader.validate!([Map.put(document(%{}), "id", "app.bsky.feed.post")])
    end

    for property <- [
          %{"type" => "string", "pattern" => "ignored"},
          %{"type" => "string", "format" => "unknown"},
          %{"type" => "integer", "minimum" => 1, "default" => 0},
          %{"type" => "integer", "default" => 1, "enum" => nil},
          %{"type" => "ref", "ref" => "app.bsky.graph.defs#listView"},
          %{"type" => "ref", "ref" => "com.example.missing"},
          %{"type" => "integer", "minimum" => 10, "maximum" => 1},
          %{"type" => "boolean", "const" => "yes"},
          %{"type" => "union", "refs" => [], "closed" => true}
        ] do
      assert_raise ArgumentError, fn -> Loader.validate!([document(%{"value" => property})]) end
    end
  end

  test "bounds file count and bytes and refuses symlinks", %{dir: dir} do
    path = Path.join(dir, "large.json")
    File.write!(path, String.duplicate(" ", 262_145))
    assert_raise ArgumentError, ~r/size limit/, fn -> Loader.load!(dir) end
    File.rm!(path)
    File.write!(Path.join(dir, "source.txt"), Jason.encode!(document(%{})))
    File.ln_s!(Path.join(dir, "source.txt"), path)
    assert_raise ArgumentError, ~r/regular JSON/, fn -> Loader.load!(dir) end
    File.rm!(path)
    for n <- 1..129, do: File.write!(Path.join(dir, "#{n}.json"), "{}")
    assert_raise ArgumentError, ~r/128 files/, fn -> Loader.load!(dir) end
  end

  test "recursive object schemas terminate at the validation depth limit" do
    doc = document(%{"child" => %{"type" => "ref", "ref" => "#node"}})

    doc =
      put_in(doc, ["defs", "node"], %{
        "type" => "object",
        "properties" => %{"child" => %{"type" => "ref", "ref" => "#node"}}
      })

    Application.put_env(:atoll, :record_lexicons, Loader.validate!([doc]))
    nested = Enum.reduce(1..40, %{}, fn _, acc -> %{"child" => acc} end)

    assert {:error, :invalid_record_schema} =
             Schema.record(@id, "one", Map.put(nested, "$type", @id), true)
  end

  test "custom integer records preserve the signed 64-bit data-model range" do
    Application.put_env(
      :atoll,
      :record_lexicons,
      Loader.validate!([document(%{"count" => %{"type" => "integer"}})])
    )

    for count <- [-9_223_372_036_854_775_808, 9_223_372_036_854_775_807] do
      assert {:ok, "valid"} = Schema.record(@id, "one", %{"$type" => @id, "count" => count}, true)
    end

    assert {:error, :invalid_record_schema} =
             Schema.record(
               @id,
               "one",
               %{"$type" => @id, "count" => 9_223_372_036_854_775_808},
               true
             )
  end

  defp document(properties),
    do: %{
      "lexicon" => 1,
      "id" => @id,
      "defs" => %{
        "main" => %{
          "type" => "record",
          "key" => "any",
          "record" => %{"type" => "object", "properties" => properties}
        }
      }
    }

  defp write!(dir, name, doc),
    do: File.write!(Path.join(dir, name <> ".json"), Jason.encode!(doc))
end
