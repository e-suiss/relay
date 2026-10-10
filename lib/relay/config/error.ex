defmodule Relay.Config.Error do
  @moduledoc "Raised when configuration is unknown, missing or malformed at startup."

  defexception [:message]
end
