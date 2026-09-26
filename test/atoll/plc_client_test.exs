defmodule Atoll.PLCClientTest do
  use ExUnit.Case, async: false
  alias Atoll.Identity.PLC.{Client, Operation}

  setup do
    previous = Application.get_env(:atoll, :plc_directory_url)
    Application.put_env(:atoll, :plc_directory_url, "https://directory.example.com")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:atoll, :plc_directory_url, previous),
        else: Application.delete_env(:atoll, :plc_directory_url)
    end)

    [first, second] =
      File.read!(Path.join([__DIR__, "..", "fixtures", "plc", "log_bskyapp.json"]))
      |> Jason.decode!()

    %{did: first["did"], operation: first["operation"], later: second["operation"]}
  end

  test "submits the exact operation to the configured directory and confirms its latest CID",
       ctx do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "directory.example.com"
      assert URI.decode(conn.request_path) == "/" <> ctx.did
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == ctx.operation
      Plug.Conn.send_resp(conn, 200, "")
    end)

    expect_latest(ctx)

    assert :ok =
             Client.submit_genesis(ctx.did, ctx.operation,
               plug: {Req.Test, __MODULE__},
               url: "https://ignored.example.com",
               retry: true
             )
  end

  test "ambiguous errors and duplicate submissions succeed only with matching latest operation",
       ctx do
    for status <- [400, 409, 429, 503] do
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, status, "directory error"))
      expect_latest(ctx)
      assert :ok = submit(ctx)
    end

    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))
    expect_latest(ctx)
    assert :ok = submit(ctx)
  end

  test "a successful POST does not prove registration or ownership of the latest state", ctx do
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 200, ""))
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, ctx.later))
    assert {:error, :plc_conflict} = submit(ctx)

    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 200, ""))
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 404, ""))
    assert {:error, :plc_unavailable} = submit(ctx)
  end

  test "only definitive rejection with an absent identity is classified as rejected", ctx do
    for {status, reason} <- [
          {400, :plc_rejected},
          {403, :plc_rejected},
          {408, :plc_unavailable},
          {429, :plc_unavailable},
          {500, :plc_unavailable}
        ] do
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, status, "sensitive error"))
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 404, ""))
      assert {:error, ^reason} = submit(ctx)
    end
  end

  test "rejects malformed, oversized, and encoded responses", ctx do
    for body <- ["not JSON", "null", "{}", String.duplicate(" ", 65_537)] do
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 200, ""))
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 200, body))
      assert {:error, :invalid_plc_response} = submit(ctx)
    end

    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 200, ""))

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "gzip")
      |> Plug.Conn.send_resp(200, :zlib.gzip(Jason.encode!(ctx.operation)))
    end)

    assert {:error, :invalid_plc_response} = submit(ctx)
  end

  test "never follows redirects or automatically retries either request", ctx do
    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://other.example.com")
      |> Plug.Conn.send_resp(307, "")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.host == "directory.example.com"

      conn
      |> Plug.Conn.put_resp_header("location", "https://other.example.com")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, :plc_unavailable} = submit(ctx)

    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 503, ""))
    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))
    assert {:error, :plc_unavailable} = submit(ctx)
  end

  test "invalid genesis or directory configuration never reaches the network", ctx do
    assert {:error, :invalid_plc_operation} =
             Client.submit_genesis(ctx.did, Map.put(ctx.operation, "sig", "bad"))

    assert {:error, :invalid_plc_operation} =
             Client.submit_genesis("did:plc:aaaaaaaaaaaaaaaaaaaaaaaa", ctx.operation)

    assert {:ok, _} = Operation.cid(ctx.later)
    assert {:error, :invalid_plc_operation} = Client.submit_genesis(ctx.did, ctx.later)

    Application.put_env(:atoll, :plc_directory_url, "http://directory.example.com")
    assert {:error, :invalid_plc_directory} = submit(ctx)
  end

  test "validates the configured HTTPS origin with sanitized errors" do
    assert Client.directory_from_env!(nil) == "https://plc.directory"

    assert Client.directory_from_env!("https://directory.example.com:8443/") ==
             "https://directory.example.com:8443"

    for value <- [
          "",
          "http://plc.directory",
          "https://secret@plc.directory",
          "https://plc.directory?secret=1",
          "https://plc.directory/#secret",
          "https://plc.directory/path",
          "https://plc.directory:0",
          "https://plc.directory:65536",
          "https://bad host",
          123
        ] do
      error = assert_raise RuntimeError, fn -> Client.directory_from_env!(value) end
      refute error.message =~ "secret"
    end
  end

  test "updates verify the predecessor before posting and confirm the exact signed result", ctx do
    expect_latest(ctx)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "directory.example.com"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == ctx.later
      Plug.Conn.send_resp(conn, 200, "")
    end)

    expect_latest(%{ctx | operation: ctx.later})
    assert :ok = update(ctx)

    # A retry of the persisted operation needs no second POST.
    expect_latest(%{ctx | operation: ctx.later})
    assert :ok = update(ctx)
  end

  test "update transport failures are reconciled against the exact latest operation", ctx do
    for status <- [400, 409, 429, 503] do
      expect_latest(ctx)
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, status, "error"))
      expect_latest(%{ctx | operation: ctx.later})
      assert :ok = update(ctx)
    end

    expect_latest(ctx)
    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))
    expect_latest(%{ctx | operation: ctx.later})
    assert :ok = update(ctx)
  end

  test "unchanged latest state is not proof of update acceptance", ctx do
    for {status, reason} <- [
          {200, :plc_unavailable},
          {400, :plc_rejected},
          {409, :plc_rejected},
          {429, :plc_unavailable},
          {500, :plc_unavailable}
        ] do
      expect_latest(ctx)
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, status, "error"))
      expect_latest(ctx)
      assert {:error, ^reason} = update(ctx)
    end
  end

  test "conflicting latest operations and malformed reads prevent update POSTs", ctx do
    [foreign | _] =
      File.read!(Path.join([__DIR__, "..", "fixtures", "plc", "log_bnewbold_robocracy.json"]))
      |> Jason.decode!()

    Req.Test.expect(__MODULE__, &Req.Test.json(&1, foreign["operation"]))
    assert {:error, :plc_conflict} = update(ctx)

    for body <- ["null", "{}", String.duplicate(" ", 65_537)] do
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 200, body))
      assert {:error, :invalid_plc_response} = update(ctx)
    end

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://other.example.com")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, :plc_unavailable} = update(ctx)

    expect_latest(ctx)
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 200, ""))
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, foreign["operation"]))
    assert {:error, :plc_conflict} = update(ctx)
  end

  test "invalid update signatures, predecessor links and DIDs never reach the network", ctx do
    assert {:error, :invalid_plc_operation} =
             update(%{ctx | later: Map.put(ctx.later, "sig", "bad")})

    assert {:error, :invalid_plc_operation} =
             update(%{ctx | later: Map.put(ctx.later, "prev", nil)})

    assert {:error, :invalid_plc_operation} = update(%{ctx | did: "did:web:example.com"})
    assert {:error, :invalid_plc_operation} = update(%{ctx | did: nil})
  end

  defp update(ctx),
    do: Client.submit_update(ctx.did, ctx.operation, ctx.later, plug: {Req.Test, __MODULE__})

  defp submit(ctx),
    do: Client.submit_genesis(ctx.did, ctx.operation, plug: {Req.Test, __MODULE__})

  defp expect_latest(ctx) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.host == "directory.example.com"
      assert URI.decode(conn.request_path) == "/" <> ctx.did <> "/log/last"
      assert Plug.Conn.get_req_header(conn, "accept-encoding") == ["identity"]
      Req.Test.json(conn, ctx.operation)
    end)
  end
end
