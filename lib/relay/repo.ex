defmodule Relay.Repo do
  @moduledoc "The PostgreSQL repository. Only `*.Store` modules call it (T-60)."

  use Ecto.Repo, otp_app: :relay, adapter: Ecto.Adapters.Postgres
end
