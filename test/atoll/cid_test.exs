defmodule Atoll.CIDTest do
  use ExUnit.Case, async: true

  alias Atoll.CID

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
end
