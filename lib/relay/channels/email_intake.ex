defmodule Relay.Channels.EmailIntake do
  @moduledoc """
  The intake of verified provider e-mail events (CH-39, CH-40, CH-47, DS-10), for a reader that has already verified the request or the SNS envelope and parsed its events (`Relay.Channels.email_events/2`); see `Relay.Channels.Live.EmailEvents`. A provider webhook goes through the durable receipt path instead (`Relay.Channels.Live.accept_provider_webhook/4`, WH-49).
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Channels.Live],
    exports: []

  @type outcome :: Relay.Channels.Live.email_outcome()

  # CH-39
  # CH-40
  # CH-47
  # DS-10
  @doc "Records the events of one verified provider payload in `scope` and applies their suppressions; returns one outcome per event."
  @spec ingest(Relay.Scope.t(), [map()]) :: {:ok, [outcome()]} | {:error, term()}
  def ingest(%Relay.Scope{} = scope, events) when is_list(events),
    do: Relay.Channels.Live.ingest_email_events(scope, events)
end
