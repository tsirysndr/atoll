defmodule AtollWeb.HomeController do
  use AtollWeb, :controller

  def show(conn, _params) do
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
