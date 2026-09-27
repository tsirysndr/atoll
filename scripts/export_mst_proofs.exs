# Offline fixture export; no application start, repository writes or network access.
[input, output] = System.argv()
alias Atoll.{CID, CBOR}

decode_cid = fn value ->
  {:ok, cid} = CID.from_base32(value)
  cid
end

link = fn value -> if value, do: %CBOR.Link{cid: decode_cid.(value)}, else: nil end
source = input |> File.read!() |> Jason.decode!()

fixtures =
  Enum.map(source["fixtures"], fn fixture ->
    blocks =
      Map.new(fixture["afterBlocks"], fn {cid, bytes} ->
        {decode_cid.(cid), Base.decode64!(bytes)}
      end)

    ops =
      Enum.map(fixture["operations"], fn op ->
        op |> Map.update!("cid", link) |> Map.update!("prev", link)
      end)

    {:ok, proof} =
      Atoll.Repositories.CommitProof.build(
        decode_cid.(fixture["afterRoot"]),
        link.(fixture["beforeRoot"]),
        ops,
        &Map.fetch(blocks, &1)
      )

    fixture
    |> Map.take(["name", "beforeRoot", "afterRoot", "operations"])
    |> Map.put(
      "proof",
      Map.new(proof, fn {cid, bytes} -> {CID.to_base32(cid), Base.encode64(bytes)} end)
    )
  end)

File.write!(
  output,
  Jason.encode!(
    %{
      reference: source["reference"],
      implementationSha256: source["implementationSha256"],
      fixtures: fixtures
    },
    pretty: true
  ) <> "\n"
)

IO.puts("Exported #{length(fixtures)} Atoll partial proofs")
