defmodule Atoll.RateLimitLoopbackTest do
  use ExUnit.Case, async: false
  alias Atoll.Accounts.SessionLimiter

  setup do
    on_exit(fn -> Application.delete_env(:atoll, :rate_limit_exempt_loopback) end)
  end

  test "loopback callers are limited unless the exemption is configured" do
    refute SessionLimiter.exempt?({:xrpc, {127, 0, 0, 1}})

    Application.put_env(:atoll, :rate_limit_exempt_loopback, true)

    # Behind a gateway on the same host every request arrives from loopback.
    for address <- [
          {127, 0, 0, 1},
          {127, 1, 2, 3},
          {0, 0, 0, 0, 0, 0, 0, 1},
          {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}
        ] do
      assert SessionLimiter.exempt?({:xrpc, address}), inspect(address)
    end

    # Everyone else still has a budget.
    for address <- [{203, 0, 113, 7}, {10, 0, 0, 1}, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}] do
      refute SessionLimiter.exempt?({:xrpc, address}), inspect(address)
    end
  end

  test "an exempted key is admitted without spending a budget" do
    Application.put_env(:atoll, :rate_limit_exempt_loopback, true)
    for _ <- 1..50, do: assert(SessionLimiter.check({:loopback_probe, {127, 0, 0, 1}}, 1) == :ok)
  end
end
