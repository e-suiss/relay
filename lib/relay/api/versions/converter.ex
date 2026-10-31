defmodule Relay.Api.Versions.Converter do
  @moduledoc """
  One step of the version converter chain. Relay keeps a single internal model; each dated version that changes the shape of an operation adds a converter that turns a request of that version into the next version's form and a response of the next version back into its own form.
  """

  @doc "Turns a request body of the converter's version into the next version's form."
  @callback request(operation_id :: String.t(), body :: term()) :: term()

  @doc "Turns a response body of the next version into the converter's version."
  @callback response(operation_id :: String.t(), body :: term()) :: term()
end
