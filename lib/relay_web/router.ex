defmodule RelayWeb.Router do
  use RelayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RelayWeb do
    pipe_through :api

    get "/livez", HealthController, :live
    get "/readyz", HealthController, :ready
  end
end
