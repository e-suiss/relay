defmodule Relay.Audit.Checkpointer.Publisher.Siem do
  @moduledoc """
  Publication target on a SIEM's HTTPS intake (`siem`). Each signed checkpoint is sent as one JSON line, and the audit records themselves are streamed to the same intake in batches of JSON lines in log order (`stream/3`, run by `Relay.Audit.Checkpointer.Stream`); both are signed as `Relay.Audit.Checkpointer.Publisher.Https` describes. A record can arrive more than once; its `id` is unique. Options are those of the transport.
  """

  @behaviour Relay.Audit.Checkpointer.Publisher

  alias Relay.Audit.Checkpointer.Publisher.Https

  # TN-46
  @impl Relay.Audit.Checkpointer.Publisher
  @doc "The SIEM is a target independent of Relay's own operation."
  @spec independent?() :: true
  def independent?, do: true

  @impl Relay.Audit.Checkpointer.Publisher
  @doc "Validates the options."
  @spec validate(keyword()) :: :ok | {:error, String.t()}
  def validate(opts), do: Https.validate(opts)

  # TN-46
  @impl Relay.Audit.Checkpointer.Publisher
  @doc "Sends a signed checkpoint."
  @spec publish(Relay.Audit.Checkpointer.Publisher.checkpoint(), keyword()) ::
          :ok | {:error, Relay.Error.t()}
  def publish(checkpoint, opts), do: Https.post(Https.checkpoint_line(checkpoint), opts)

  # TN-49
  @doc "Sends a batch of audit records of the log `origin` as JSON lines."
  @spec stream(String.t(), [map()], keyword()) :: :ok | {:error, Relay.Error.t()}
  def stream(_origin, [], _opts), do: :ok

  def stream(origin, records, opts),
    do: Https.post(Enum.map_join(records, &Https.record_line(origin, &1)), opts)
end
