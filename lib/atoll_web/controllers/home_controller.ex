defmodule AtollWeb.HomeController do
  use AtollWeb, :controller

  def show(conn, _params) do
    host = String.downcase(conn.host)

    if rocksky_profile?(host) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> redirect(external: "https://rocksky.app/profile/" <> host)
    else
      landing_page(conn)
    end
  end

  defp rocksky_profile?(host) do
    host != URI.parse(AtollWeb.Endpoint.url()).host and
      String.ends_with?(host, ".rocksky.social") and
      Atoll.Accounts.Signup.hosted_handle?(host) and
      case Atoll.Repo.get_by(Atoll.Accounts.Profile, handle: host) do
        %{did: did} -> not Atoll.Accounts.Signup.pending?(did)
        nil -> false
      end
  end

  defp landing_page(conn) do
    text(conn, ~S"""
             __                         __
            /\ \__                     /\ \__
        __  \ \ ,_\  _____   _ __   ___\ \ ,_\   ___
      /'__'\ \ \ \/ /\ '__'\/\''__\/ __'\ \ \/  / __'\
     /\ \L\.\_\ \ \_\ \ \L\ \ \ \//\ \L\ \ \ \_/\ \L\ \
     \ \__/.\_\\ \__\\ \ ,__/\ \_\\ \____/\ \__\ \____/
      \/__/\/_/ \/__/ \ \ \/  \/_/ \/___/  \/__/\/___/
                       \ \_\
                        \/_/


    This is an AT Protocol Personal Data Server (aka, an atproto PDS)

    Most API routes are under /xrpc/
    """)
  end
end
