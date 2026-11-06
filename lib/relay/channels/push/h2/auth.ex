defmodule Relay.Channels.Push.H2.Auth do
  @moduledoc """
  The `authorization` header source of an HTTP/2 connection (CH-25, TN-29, TN-30). The connection keeps the source's state, so a provider token is cached per connection and its renewal rules (the APNs 20-minute floor) hold per connection; the configuration comes with every request, so a rotated credential applies at the next request without dropping the connection.
  """

  @doc "The state of a new connection."
  @callback init(config :: term()) :: term()

  @doc "The `authorization` header value at Unix time `now` in seconds, and the new state."
  @callback authorization(config :: term(), state :: term(), now :: integer()) ::
              {:ok, String.t(), term()} | {:error, Relay.Error.t(), term()}
end
