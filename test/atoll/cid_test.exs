defmodule Atoll.CIDTest do
  use ExUnit.Case, async: true

  alias Atoll.CID

  @empty_map_cid "bafyreigbtj4x7ip5legnfznufuopl4sg4knzc2cof6duas4b3q2fy6swua"

  test "constructs a DAG-CBOR CID for an encoded empty map" do
    # CBOR encodes an empty map as the single byte 0xA0.
    digest =
      Base.decode16!(
        "c19a797fa1fd590cd2e5b42d1cf5f246e29b91684e2f87404b81dc345c7a56a0",
        case: :lower
      )

    assert CID.create(<<0xA0>>, :dag_cbor) ==
             <<1, 0x71, 0x12, 32, digest::binary>>
  end

  test "constructs a raw CID using the SHA-256 digest of its content" do
    digest =
      Base.decode16!(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        case: :lower
      )

    assert CID.create("abc", :raw) ==
             <<1, 0x55, 0x12, 32, digest::binary>>
  end

  test "formats the empty map CID as a base32 string" do
    cid = CID.create(<<0xA0>>, :dag_cbor)

    assert CID.to_base32(cid) ==
             "bafyreigbtj4x7ip5legnfznufuopl4sg4knzc2cof6duas4b3q2fy6swua"
  end

  test "decodes a known DAG-CBOR CID" do
    digest =
      Base.decode16!(
        "c19a797fa1fd590cd2e5b42d1cf5f246e29b91684e2f87404b81dc345c7a56a0",
        case: :lower
      )

    cid = <<1, 0x71, 0x12, 32, digest::binary>>

    assert CID.decode(cid) ==
             {:ok, %{codec: :dag_cbor, digest: digest}}
  end

  test "decodes a known raw CID" do
    digest =
      Base.decode16!(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        case: :lower
      )

    cid = <<1, 0x55, 0x12, 32, digest::binary>>

    assert CID.decode(cid) ==
             {:ok, %{codec: :raw, digest: digest}}
  end

  test "rejects unsupported versions, codecs, hashes, and digest lengths" do
    digest = :binary.copy(<<0>>, 32)

    for header <- [
          <<0, 0x71, 0x12, 32>>,
          <<2, 0x71, 0x12, 32>>,
          <<1, 0x70, 0x12, 32>>,
          <<1, 0x71, 0x13, 32>>,
          <<1, 0x71, 0x12, 31>>
        ] do
      assert CID.decode(header <> digest) == {:error, :invalid_cid}
    end
  end

  test "rejects incomplete headers" do
    for bytes <- [<<>>, <<1>>, <<1, 0x71>>, <<1, 0x71, 0x12>>, <<128>>] do
      assert CID.decode(bytes) == {:error, :invalid_cid}
    end
  end

  test "rejects truncated digests and trailing bytes" do
    for size <- [0, 31, 33] do
      digest = :binary.copy(<<0>>, size)

      assert CID.decode(<<1, 0x71, 0x12, 32, digest::binary>>) ==
               {:error, :invalid_cid}
    end
  end

  test "rejects non-minimal varints in every header field" do
    digest = :binary.copy(<<0>>, 32)

    for header <- [
          <<129, 0, 0x71, 0x12, 32>>,
          <<1, 241, 0, 0x12, 32>>,
          <<1, 0x71, 146, 0, 32>>,
          <<1, 0x71, 0x12, 160, 0>>
        ] do
      assert CID.decode(header <> digest) == {:error, :invalid_cid}
    end
  end

  test "parses a known base32 CID" do
    expected =
      Base.decode16!(
        "01711220c19a797fa1fd590cd2e5b42d1cf5f246e29b91684e2f87404b81dc345c7a56a0",
        case: :lower
      )

    assert CID.from_base32(@empty_map_cid) == {:ok, expected}
  end

  test "round-trips a raw CID through base32" do
    cid = CID.create("abc", :raw)

    assert CID.from_base32(CID.to_base32(cid)) == {:ok, cid}
  end

  test "rejects incorrect prefixes, case, lengths, and characters" do
    for text <- [
          "",
          "b",
          String.replace_prefix(@empty_map_cid, "b", "z"),
          String.upcase(@empty_map_cid),
          "b" <> String.upcase(binary_part(@empty_map_cid, 1, 58)),
          @empty_map_cid <> "=",
          @empty_map_cid <> "a",
          "b" <> String.duplicate("!", 58)
        ] do
      assert CID.from_base32(text) == {:error, :invalid_cid}
    end
  end

  test "rejects nonzero unused bits in the final base32 character" do
    # Changing the final "a" to "b" changes only unused encoding bits.
    text = binary_part(@empty_map_cid, 0, 58) <> "b"

    assert CID.from_base32(text) == {:error, :invalid_cid}
  end

  test "rejects valid base32 containing an unsupported CID" do
    digest = :binary.copy(<<0>>, 32)
    invalid_cid = <<2, 0x71, 0x12, 32, digest::binary>>
    text = "b" <> Base.encode32(invalid_cid, case: :lower, padding: false)

    assert CID.from_base32(text) == {:error, :invalid_cid}
  end

  test "rejects non-string inputs" do
    for value <- [nil, 123, true, [], %{}] do
      assert CID.from_base32(value) == {:error, :invalid_cid}
    end
  end

  test "verifies content against a known raw CID" do
    cid =
      Base.decode16!(
        "01551220ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        case: :lower
      )

    assert CID.verify(cid, "abc") == :ok
  end

  test "verifies encoded CBOR against a known DAG-CBOR CID" do
    {:ok, cid} = CID.from_base32(@empty_map_cid)

    assert CID.verify(cid, <<0xA0>>) == :ok
  end

  test "rejects content that does not match the digest" do
    {:ok, cid} = CID.from_base32(@empty_map_cid)

    for content <- [<<>>, <<0xA1>>, "{}", <<0xA0, 0>>] do
      assert CID.verify(cid, content) == {:error, :content_mismatch}
    end
  end

  test "rejects malformed CIDs before verifying content" do
    digest = :crypto.hash(:sha256, "abc")

    for cid <- [
          <<>>,
          <<1, 0x55>>,
          <<2, 0x55, 0x12, 32, digest::binary>>,
          <<1, 0x55, 0x12, 32, digest::binary, 0>>
        ] do
      assert CID.verify(cid, "abc") == {:error, :invalid_cid}
    end
  end
end
