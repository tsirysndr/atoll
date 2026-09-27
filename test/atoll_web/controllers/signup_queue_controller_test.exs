defmodule AtollWeb.SignupQueueControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Repositories, SigningKey}
  alias Atoll.Accounts.{Credentials, Sessions}
  @did "did:plc:signupqueue"
  @route "/xrpc/com.atproto.temp.checkSignupQueue"

  setup %{conn: conn} do
    previous = Application.fetch_env(:atoll, :session_signing_key)
    Application.put_env(:atoll, :session_signing_key, :binary.copy(<<31>>, 32))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:atoll, :session_signing_key, value)
        :error -> Application.delete_env(:atoll, :session_signing_key)
      end
    end)

    {:ok, _} = Repositories.create(@did, SigningKey.generate())
    {:ok, _} = Credentials.create(@did, "signup queue password")
    {:ok, pair} = Sessions.create(@did, "signup queue password")
    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 63, div(id, 256), rem(id, 256)}}, pair: pair}
  end

  defp query(c, jwt),
    do: c.conn |> put_req_header("authorization", "Bearer " <> jwt) |> get(@route)

  test "reports live sessions as activated without a queue", c do
    response = query(c, c.pair.access_jwt)
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert json_response(response, 200) == %{"activated" => true}

    {:ok, _} = Repositories.set_status(@did, :deactivated)
    assert query(c, c.pair.access_jwt) |> json_response(200) == %{"activated" => true}
  end

  test "requires a live session and refuses other methods and bodies", c do
    assert c.conn |> get(@route) |> json_response(401)
    assert query(c, c.pair.refresh_jwt) |> json_response(401)
    assert c.conn |> post(@route) |> json_response(405)
    {:ok, :ok} = Sessions.revoke(c.pair.refresh_jwt)
    assert query(c, c.pair.access_jwt) |> json_response(401)
  end
end
