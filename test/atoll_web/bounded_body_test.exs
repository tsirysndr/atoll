defmodule AtollWeb.BoundedBodyTest do
  use ExUnit.Case, async: true
  alias AtollWeb.BoundedBody

  test "assembles multiple chunks exactly and rejects bytes beyond the limit" do
    bytes = :crypto.strong_rand_bytes(100_000)
    conn = Plug.Test.conn(:post, "/", bytes)
    assert {:ok, ^bytes, _} = BoundedBody.read(conn, 100_000)
    assert {:error, :request_too_large, _} = BoundedBody.read(conn, 99_999)
    assert {:ok, "", _} = BoundedBody.read(Plug.Test.conn(:post, "/", ""), 0)
  end
end
