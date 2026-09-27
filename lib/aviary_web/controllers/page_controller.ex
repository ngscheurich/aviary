defmodule AviaryWeb.PageController do
  use AviaryWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
