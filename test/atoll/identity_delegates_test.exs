defmodule Atoll.Identity.DelegatesTest do
  use ExUnit.Case, async: false
  alias Atoll.Identity.Delegates

  @did "did:plc:4zc47fuogx2rdgxolokayzaw"

  setup do
    previous = Application.get_env(:atoll, :handle_delegates)
    Application.put_env(:atoll, :handle_delegates, ["https://sibling.example.com"])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:atoll, :handle_delegates, previous),
        else: Application.delete_env(:atoll, :handle_delegates)
    end)
  end

  test "asks the delegate for the handle and returns the DID it names" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/xrpc/com.atproto.identity.resolveHandle"
      assert conn.query_string == "handle=alice.example.com"
      Req.Test.json(conn, %{did: @did})
    end)

    assert {:ok, @did} =
             Delegates.resolve("alice.example.com", plug: {Req.Test, __MODULE__})
  end

  test "an unknown handle is not claimed" do
    Req.Test.expect(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 400, ~s({"error":"UnableToResolveHandle"}))
    end)

    assert :error = Delegates.resolve("nobody.example.com", plug: {Req.Test, __MODULE__})
  end

  test "a delegate cannot answer with something that is not a DID" do
    for answer <- ["not-a-did", "did:plc:short", "", "did:plc:4zc47fuogx2rdgxolokayzaw\nX"] do
      Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, %{did: answer}) end)
      assert :error = Delegates.resolve("alice.example.com", plug: {Req.Test, __MODULE__})
    end
  end

  test "a handle that is not a hostname is never asked about" do
    # No Req.Test expectation is set, so any request would fail the test.
    assert :error = Delegates.resolve("alice example.com")
    assert :error = Delegates.resolve("ALICE.example.com")
    assert :error = Delegates.resolve("")
    assert :error = Delegates.resolve(nil)
  end

  test "no delegates configured means nothing is asked" do
    Application.put_env(:atoll, :handle_delegates, [])
    assert :error = Delegates.resolve("alice.example.com")
  end

  describe "parse!/2" do
    test "reads a comma-separated list of origins and trims trailing slashes" do
      env = %{"ATOLL_HANDLE_DELEGATES" => "https://a.example.com/, http://b.example.com"}
      assert Delegates.parse!(env) == ["https://a.example.com", "http://b.example.com"]
    end

    test "falls back to the existing setting when unset" do
      assert Delegates.parse!(%{}, ["https://kept.example.com"]) == ["https://kept.example.com"]
      assert Delegates.parse!(%{}) == []
    end

    test "an empty value disables delegation" do
      assert Delegates.parse!(%{"ATOLL_HANDLE_DELEGATES" => ""}) == []
    end

    test "anything that is not a bare origin is refused" do
      for value <- [
            "https://a.example.com/xrpc",
            "ftp://a.example.com",
            "https://user@a.example.com",
            "https://a.example.com?x=1",
            "not a url"
          ] do
        assert_raise RuntimeError, fn ->
          Delegates.parse!(%{"ATOLL_HANDLE_DELEGATES" => value})
        end
      end
    end
  end
end
