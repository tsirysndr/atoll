defmodule AtollWeb.HealthControllerTest do
  use AtollWeb.ConnCase, async: true

  setup do
    handler = {__MODULE__, make_ref()}
    owner = self()

    :ok =
      :telemetry.attach(handler, [:atoll, :readiness, :check], &__MODULE__.telemetry/4, owner)

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  test "readiness probes the test database and records duration", %{conn: conn} do
    conn = get(conn, "/health/ready")
    assert json_response(conn, 200) == %{"status" => "ok"}
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert_receive {:readiness, %{count: 1, duration: duration}, %{outcome: :ready}}
    assert is_integer(duration) and duration >= 0
  end

  test "unavailable repository returns sanitized 503 while liveness remains healthy", %{
    conn: conn
  } do
    # Dynamic repo selection is local to this test process; the application repo stays running.
    prior = Atoll.Repo.put_dynamic_repo(Atoll.UnavailableReadinessTestRepo)

    try do
      ready = get(conn, "/health/ready")
      assert json_response(ready, 503) == %{"status" => "unavailable"}
      assert get_resp_header(ready, "cache-control") == ["no-store"]
      assert_receive {:readiness, %{count: 1}, %{outcome: :unavailable}}

      live = get(conn, "/health")
      assert json_response(live, 200) == %{"status" => "ok"}
      assert get_resp_header(live, "cache-control") == ["no-store"]
      refute_receive {:readiness, _, _}
    after
      Atoll.Repo.put_dynamic_repo(prior)
    end
  end

  test "PostgreSQL query failures return unavailable without leaking SQL errors", %{conn: conn} do
    assert {:error, :probe_test} =
             Atoll.Repo.transaction(fn ->
               # An explicit transaction avoids the sandbox's per-query recovery savepoints.
               assert {:error, %Postgrex.Error{}} =
                        Atoll.Repo.query("SELECT 1 / 0", [], log: false)

               assert get(conn, "/health/ready") |> json_response(503) == %{
                        "status" => "unavailable"
                      }

               assert_receive {:readiness, _, %{outcome: :unavailable}}
               Atoll.Repo.rollback(:probe_test)
             end)
  end

  test "the XRPC health route reports the version and database availability", %{conn: conn} do
    version = to_string(Application.spec(:atoll, :vsn))
    response = get(conn, "/xrpc/_health")
    assert json_response(response, 200) == %{"version" => version}
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert_receive {:readiness, _, %{outcome: :ready}}

    result = post(conn, "/xrpc/_health")
    assert json_response(result, 405)
    assert get_resp_header(result, "allow") == ["GET"]

    assert {:error, :probe_test} =
             Atoll.Repo.transaction(fn ->
               assert {:error, %Postgrex.Error{}} =
                        Atoll.Repo.query("SELECT 1 / 0", [], log: false)

               assert get(conn, "/xrpc/_health") |> json_response(503) == %{
                        "version" => version,
                        "error" => "Service Unavailable"
                      }

               Atoll.Repo.rollback(:probe_test)
             end)
  end

  def telemetry(_event, measurements, metadata, owner) do
    if self() == owner, do: send(owner, {:readiness, measurements, metadata})
  end
end
