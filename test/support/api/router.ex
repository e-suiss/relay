defmodule RelayTest.Api.Router do
  @moduledoc "A router that mounts contract operations not yet served by `RelayWeb.Router` on test controllers, so the shared API pipeline is exercised end to end."

  use Phoenix.Router, helpers: false

  use Boundary, top_level?: true, deps: [RelayWeb, RelayTest.Api.Controller], exports: []

  pipeline :v1 do
    plug RelayWeb.Api.Pipeline
  end

  scope "/v1", RelayTest.Api do
    pipe_through :v1

    get "/virtual_clock", Controller, :clock, private: %{relay_operation: "getVirtualClock"}

    post "/virtual_clock/advance", Controller, :advance,
      private: %{relay_operation: "advanceVirtualClock"}

    post "/events/batch", Controller, :batch, private: %{relay_operation: "createEventBatch"}
    get "/notifications", Controller, :list, private: %{relay_operation: "listNotifications"}
  end
end
