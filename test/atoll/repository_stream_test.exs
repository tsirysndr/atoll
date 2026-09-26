defmodule Atoll.RepositoryStreamTest do
  use Atoll.DataCase, async: false
  alias Atoll.{CAR, Repo, Repositories, SigningKey}
  @did "did:plc:streamtest"
  @collection "com.example.record"

  setup do
    key = SigningKey.generate()
    {:ok, initial} = Repositories.create(@did, key)
    %{key: key, initial: initial}
  end

  test "full and incremental streams contain the same authenticated blocks as buffered exports",
       c do
    {:ok, _} =
      Repositories.apply_writes(
        @did,
        [{:create, @collection <> "/one", %{"$type" => @collection, "text" => "hello"}}],
        c.key
      )

    for since <- [nil, c.initial.rev] do
      assert {:ok, expected} = Repositories.export(@did, since)

      assert {:ok, actual} =
               Repositories.stream_export(@did, since, nil, fn chunks ->
                 assert Repo.in_transaction?()
                 chunks |> Enum.to_list() |> IO.iodata_to_binary()
               end)

      assert CAR.decode(actual) == CAR.decode(expected)
    end
  end

  test "cancellation stops before reading record bodies, while corruption aborts a consumed stream",
       c do
    {:ok, _} =
      Repositories.apply_writes(
        @did,
        [{:create, @collection <> "/one", %{"$type" => @collection}}],
        c.key
      )

    record = Repo.get_by!(Atoll.Repositories.Record, did: @did, path: @collection <> "/one")

    Repo.update_all(from(b in Atoll.Storage.Block, where: b.cid == ^record.cid),
      set: [data: "corrupt"]
    )

    assert {:ok, [_header]} = Repositories.stream_export(@did, nil, nil, &Enum.take(&1, 1))

    assert_raise ArgumentError, "Invalid CAR stream block", fn ->
      Repositories.stream_export(@did, nil, nil, &Enum.to_list/1)
    end
  end

  test "exports more than 64 MiB without collecting the CAR", c do
    payload = String.duplicate("x", 975_000)

    writes =
      for n <- 1..70,
          do:
            {:create, @collection <> "/key#{n}",
             %{"$type" => @collection, "text" => payload, "index" => n}}

    {:ok, _} = Repositories.apply_writes(@did, writes, c.key)

    assert {:ok, size} =
             Repositories.stream_export(@did, nil, nil, fn chunks ->
               Enum.reduce(chunks, 0, &(byte_size(&1) + &2))
             end)

    assert size > 64 * 1024 * 1024
  end
end
