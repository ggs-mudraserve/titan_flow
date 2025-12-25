defmodule TitanFlowWeb.Plugs.RequireAuth do
  @moduledoc """
  Plug that requires authentication via session.
  Redirects to /login if user_authenticated is not set in session.
  """
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    if get_session(conn, :user_authenticated) do
      conn
    else
      conn
      |> redirect(to: "/login")
      |> halt()
    end
  end
end
