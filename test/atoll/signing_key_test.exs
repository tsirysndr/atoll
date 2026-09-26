defmodule Atoll.SigningKeyTest do
  use ExUnit.Case, async: true
  alias Atoll.SigningKey

  @p_order 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
  @k_order 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

  test "verifies the independent RFC 6979 P-256 SHA-256 sample after low-S normalization" do
    # https://www.rfc-editor.org/rfc/rfc6979#appendix-A.2.5
    private = Base.decode16!("C9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721")
    public = Base.decode16!("0360FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6")
    r = 0xEFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716
    high_s = 0xF7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8
    assert {:ok, key} = SigningKey.from_private(:p256, private)
    assert key.public == public
    assert SigningKey.verify(:p256, public, "sample", <<r::256, @p_order - high_s::256>>)
    refute SigningKey.verify(:p256, public, "sample", <<r::256, high_s::256>>)
  end

  test "both curves sign messages once with SHA-256 and produce low-S compact signatures" do
    for {curve, order} <- [p256: @p_order, k256: @k_order] do
      key = SigningKey.generate(curve)
      assert {:ok, <<r::256, s::256>> = sig} = SigningKey.sign(key, "hello")
      assert r > 0 and r < order and s > 0 and s <= div(order, 2)
      assert SigningKey.verify(curve, key.public, "hello", sig)
      refute SigningKey.verify(curve, key.public, "changed", sig)
      refute SigningKey.verify(curve, key.public, "hello", <<r::256, order - s::256>>)
      refute SigningKey.verify(curve, SigningKey.generate(curve).public, "hello", sig)
      refute SigningKey.verify(curve, <<2, 0::256>>, "hello", sig)
      refute SigningKey.verify(curve, key.public, "hello", <<0::512>>)
      refute SigningKey.verify(curve, key.public, "hello", sig <> <<0>>)
      refute inspect(key) =~ "private"
      assert SigningKey.from_private(curve, <<0::256>>) == {:error, :invalid_key}
      assert SigningKey.from_private(curve, <<order::256>>) == {:error, :invalid_key}
    end
  end

  test "derives the standard secp256k1 generator from scalar one" do
    assert {:ok, key} = SigningKey.from_private(:k256, <<1::256>>)

    assert Base.encode16(key.public) ==
             "0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798"

    assert SigningKey.from_private(:unsupported, <<1::256>>) == {:error, :invalid_key}
    assert SigningKey.from_private(:k256, "short") == {:error, :invalid_key}
    refute SigningKey.verify(:unsupported, "bad", "message", <<0::512>>)
  end
end
