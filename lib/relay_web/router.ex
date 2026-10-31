defmodule RelayWeb.Router do
  use RelayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :v1 do
    plug RelayWeb.Api.Pipeline
  end

  scope "/", RelayWeb do
    pipe_through :api

    get "/livez", HealthController, :live
    get "/readyz", HealthController, :ready
  end

  # API-6
  scope "/v1", RelayWeb.Api do
    pipe_through :v1

    get "/errors/:code", ErrorCodeController, :show, private: %{relay_operation: "getErrorCode"}
  end
end
