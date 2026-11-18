defmodule EsuissRelay do
  @moduledoc """
  Server SDK for Relay.

    * `EsuissRelay.Client` - configuration, retries and idempotency
    * `EsuissRelay.Api` - one function for every operation of the server API
    * `EsuissRelay.Page` - lazy cursor pagination
    * `EsuissRelay.Webhook` - raw body webhook verification
    * `EsuissRelay.Agents` - waitpoints, the mailbox and the follow pattern
    * `EsuissRelay.Error` - the typed errors
  """

  alias EsuissRelay.Client

  @doc "A new client; see `EsuissRelay.Client.new/1`."
  @spec new(keyword()) :: Client.t()
  def new(opts), do: Client.new(opts)

  @doc "The API version this SDK is pinned to."
  @spec api_version() :: String.t()
  def api_version, do: Client.api_version()
end
