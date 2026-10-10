defmodule Relay.DataCase do
  @moduledoc "Case template for tests that use the real PostgreSQL database through the SQL sandbox."

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      @moduletag :integration
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Relay.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
