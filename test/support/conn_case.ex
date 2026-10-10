defmodule RelayWeb.ConnCase do
  @moduledoc "Case template for tests that exercise the HTTP edge."

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint RelayWeb.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
