defmodule Atoll.CARStageTest do
  use ExUnit.Case, async: true
  alias Atoll.{CAR, CID}
  alias Atoll.CAR.Stage

  setup do
    directory =
      Path.join(System.tmp_dir!(), "atoll-stage-test-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  test "stages unique verified blocks on disk and removes them after consumption", c do
    cid = CID.create("hello", :raw)
    empty = CID.create("", :raw)
    {:ok, chunks} = CAR.encode_stream([cid], [{cid, "hello"}, {empty, ""}, {cid, "hello"}])

    assert :consumed =
             Stage.with_chunks(
               chunks,
               fn stage ->
                 assert stage.roots == [cid]
                 assert map_size(stage.index) == 2
                 assert stage.size == 5
                 assert Stage.read(stage, cid) == {:ok, "hello"}
                 assert Stage.read(stage, empty) == {:ok, ""}

                 assert Stage.read(stage, CID.create("missing", :raw)) ==
                          {:error, :staged_block_not_found}

                 [name] = File.ls!(c.directory)
                 {:ok, stat} = File.stat(Path.join(c.directory, name))
                 assert Bitwise.band(stat.mode, 0o777) == 0o700
                 :consumed
               end,
               directory: c.directory
             )

    assert File.ls!(c.directory) == []
  end

  test "malformed or truncated input never reaches the consuming callback", c do
    cid = CID.create("hello", :raw)
    {:ok, archive} = CAR.encode([cid], %{cid => "hello"})

    for bytes <- ["bad", binary_part(archive, 0, byte_size(archive) - 1), archive <> <<0>>] do
      assert {:error, :invalid_car} =
               Stage.with_chunks([bytes], fn _ -> flunk("invalid archive reached consumer") end,
                 directory: c.directory
               )

      assert File.ls!(c.directory) == []
    end
  end

  test "consumer exceptions and size limits clean up private staging", c do
    {:ok, chunks} = CAR.encode_stream([], [])

    assert_raise RuntimeError, "consumer failed", fn ->
      Stage.with_chunks(chunks, fn _ -> raise "consumer failed" end, directory: c.directory)
    end

    assert File.ls!(c.directory) == []

    assert {:error, :car_too_large} =
             Stage.with_chunks(chunks, fn _ -> flunk("over limit") end,
               directory: c.directory,
               max_bytes: 1
             )

    assert File.ls!(c.directory) == []
  end
end
