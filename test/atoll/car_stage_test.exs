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
                 assert stage.blocks == 2
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

  test "large stages use the disk index for repeated and empty blocks", c do
    blocks =
      Stream.map(1..5000, fn n ->
        bytes = Integer.to_string(n)
        {CID.create(bytes, :raw), bytes}
      end)

    {:ok, chunks} = CAR.encode_stream([], Stream.concat(blocks, blocks))

    assert :ok =
             Stage.with_chunks(
               chunks,
               fn stage ->
                 assert stage.blocks == 5000

                 assert stage.size ==
                          Enum.reduce(1..5000, 0, &(byte_size(Integer.to_string(&1)) + &2))

                 for n <- [1, 2, 255, 256, 1000, 4999, 5000] do
                   bytes = Integer.to_string(n)
                   assert Stage.read(stage, CID.create(bytes, :raw)) == {:ok, bytes}
                 end

                 [directory] = File.ls!(c.directory)

                 assert Enum.sort(File.ls!(Path.join(c.directory, directory))) == [
                          "blocks",
                          "index"
                        ]

                 :ok
               end,
               directory: c.directory,
               max_blocks: 10_000
             )

    assert File.ls!(c.directory) == []
  end

  test "damaged index offsets, sizes and slots fail closed", c do
    cid = CID.create("hello", :raw)
    {:ok, chunks} = CAR.encode_stream([], [{cid, "hello"}])

    assert :ok =
             Stage.with_chunks(
               chunks,
               fn stage ->
                 index = stage.index
                 <<hash::unsigned-64, _::binary>> = :crypto.mac(:hmac, :sha256, index.key, cid)
                 slot = rem(hash, index.slots)

                 for {offset, size} <- [{stage.size + 1, 5}, {0, 4_294_967_295}, {0, 4}] do
                   assert :ok = Atoll.CAR.StageIndex.put(index, slot, cid, offset, size)
                   assert Stage.read(stage, cid) == {:error, :staged_block_not_found}
                 end

                 assert :ok = :file.pwrite(index.io, slot * 48, <<255>>)
                 assert Stage.read(stage, cid) == {:error, :staged_block_not_found}
                 :ok
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

  test "stateful readers preserve final source state and clean up read failures", c do
    {:ok, archive} = CAR.encode([], %{})
    next = fn :start -> {:ok, archive, :finished} end

    assert :consumed =
             Stage.with_reader(
               :start,
               next,
               fn stage, :finished ->
                 assert stage.roots == []
                 :consumed
               end,
               directory: c.directory
             )

    assert File.ls!(c.directory) == []

    next = fn
      :start -> {:more, archive, :read_again}
      :read_again -> {:error, :request_timeout, :timed_out}
    end

    assert {:error, :request_timeout, :timed_out} =
             Stage.with_reader(
               :start,
               next,
               fn _, _ -> flunk("failed reader reached consumer") end,
               directory: c.directory
             )

    assert File.ls!(c.directory) == []
  end

  test "a killed request releases its supervised staging file", c do
    parent = self()

    owner =
      start_supervised!(
        {Task,
         fn ->
           {:ok, lease, io, _index} = Atoll.CAR.StageLease.open(c.directory)
           :ok = :file.pwrite(io, 0, "partial upload")
           send(parent, {:staging, lease})

           receive do
             :finish -> :ok
           end
         end}
      )

    assert_receive {:staging, lease}
    owner_ref = Process.monitor(owner)
    lease_ref = Process.monitor(lease)
    assert length(File.ls!(c.directory)) == 1
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}
    assert_receive {:DOWN, ^lease_ref, :process, ^lease, :normal}
    assert File.ls!(c.directory) == []
  end

  test "concurrency admission is bounded and configurable", c do
    assert Atoll.CAR.StageLease.limit_from_env!(nil) == 16
    assert Atoll.CAR.StageLease.limit_from_env!("1") == 1

    for value <- ["0", "65", "bad"],
        do:
          assert_raise(RuntimeError, fn ->
            Atoll.CAR.StageLease.limit_from_env!(value)
          end)

    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one, max_children: 1})
    child = {Atoll.CAR.StageLease, owner: self(), parent: c.directory}
    assert {:ok, lease} = DynamicSupervisor.start_child(supervisor, child)
    assert {:error, :max_children} = DynamicSupervisor.start_child(supervisor, child)
    Atoll.CAR.StageLease.close(lease)
    assert {:ok, next} = DynamicSupervisor.start_child(supervisor, child)
    Atoll.CAR.StageLease.close(next)
    assert File.ls!(c.directory) == []
  end
end
