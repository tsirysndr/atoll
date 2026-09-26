defmodule Atoll.TOTPTest do
  use ExUnit.Case, async: true
  alias Atoll.Accounts.TOTP
  @secret "12345678901234567890"

  test "matches the SHA-1 RFC 6238 vectors at six digits, including post-2038 timestamps" do
    # RFC 6238 Appendix B provides eight digits; these are the six-digit suffixes.
    for {time, expected} <- [
          {59, "287082"},
          {1_111_111_109, "081804"},
          {1_111_111_111, "050471"},
          {1_234_567_890, "005924"},
          {2_000_000_000, "279037"},
          {20_000_000_000, "353130"}
        ] do
      assert {:ok, ^expected} = TOTP.code(@secret, time)
      assert {:ok, step} = TOTP.verify(@secret, expected, time, -1)
      assert step == div(time, 30)
      assert {:error, :invalid_totp} = TOTP.verify(@secret, expected, time, step)
    end
  end

  test "matches all ten RFC 4226 SHA-1 counter vectors" do
    vectors = ~w(755224 287082 359152 969429 338314 254676 287922 162583 399871 520489)

    for {expected, step} <- Enum.with_index(vectors),
        do: assert({:ok, ^expected} = TOTP.code(@secret, step * 30))
  end

  test "accepts only the bounded clock window and steps beyond persisted use" do
    assert {:ok, 0} = TOTP.verify(@secret, "755224", 30, -1)
    assert {:ok, 1} = TOTP.verify(@secret, "287082", 30, -1)
    assert {:ok, 2} = TOTP.verify(@secret, "359152", 30, -1)
    assert {:error, :invalid_totp} = TOTP.verify(@secret, "969429", 30, -1)
    assert {:error, :invalid_totp} = TOTP.verify(@secret, "755224", 60, -1)
    assert {:error, :invalid_totp} = TOTP.verify(@secret, "287082", 30, 2)
    assert {:error, :invalid_totp} = TOTP.verify(@secret, "359152", 30, 2)
    assert {:ok, 3} = TOTP.verify(@secret, "969429", 90, 2)
    assert {:ok, 0} = TOTP.verify(@secret, "755224", 0, -1)
    assert TOTP.code(@secret, 29) == TOTP.code(@secret, 0)
    refute TOTP.code(@secret, 29) == TOTP.code(@secret, 30)
  end

  test "requires exactly six ASCII digits and valid bounded inputs" do
    for value <- [287_082, nil, "", "28708", "0287082", " 287082", "287082\n", "abcdef", "１２３４５６"] do
      assert {:error, :invalid_totp} = TOTP.verify(@secret, value, 59, -1)
    end

    for secret <- [nil, "", "short", :binary.copy(<<0>>, 65)] do
      assert {:error, :invalid_totp_parameters} = TOTP.code(secret, 59)
      assert {:error, :invalid_totp} = TOTP.verify(secret, "287082", 59, -1)
    end

    for time <- [-1, 1.0, nil, "59", 18_446_744_073_709_551_616 * 30] do
      assert {:error, :invalid_totp_parameters} = TOTP.code(@secret, time)
      assert {:error, :invalid_totp} = TOTP.verify(@secret, "287082", time, -1)
    end

    for used <- [-2, nil, "1", 18_446_744_073_709_551_616],
        do: assert({:error, :invalid_totp} = TOTP.verify(@secret, "287082", 59, used))
  end

  test "supports the unsigned 64-bit moving factor without overflow in the drift window" do
    time = 18_446_744_073_709_551_615 * 30
    assert {:ok, code} = TOTP.code(@secret, time)
    assert {:ok, 18_446_744_073_709_551_615} = TOTP.verify(@secret, code, time, -1)
  end

  test "provisioning URIs encode labels and declare the exact verifier profile" do
    {:ok, uri} = TOTP.provisioning_uri(@secret, "owner+test@example.com", "Atoll & friends")
    parsed = URI.parse(uri)
    assert parsed.scheme == "otpauth"
    assert parsed.host == "totp"
    assert URI.decode(parsed.path) == "/Atoll & friends:owner+test@example.com"

    assert URI.decode_query(parsed.query) == %{
             "secret" => "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
             "issuer" => "Atoll & friends",
             "algorithm" => "SHA1",
             "digits" => "6",
             "period" => "30"
           }

    for label <- [nil, "", "issuer:account", "line\nbreak", <<255>>, String.duplicate("x", 257)] do
      assert {:error, :invalid_totp_parameters} = TOTP.provisioning_uri(@secret, label)
      assert {:error, :invalid_totp_parameters} = TOTP.provisioning_uri(@secret, "account", label)
    end
  end

  test "generated enrollment secrets have 160 bits and are independent" do
    first = TOTP.generate_secret()
    second = TOTP.generate_secret()
    assert byte_size(first) == 20
    assert byte_size(second) == 20
    refute first == second
  end
end
