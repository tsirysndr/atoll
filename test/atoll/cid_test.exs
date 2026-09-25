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
end
