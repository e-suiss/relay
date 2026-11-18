defmodule Relay.Audit.Checkpointer.Publisher.Customer do
  @moduledoc """
  A customer's own publication target (`customer:<id>`), so that a customer verifies the log without asking Relay. `kind: :webhook` sends each signed checkpoint as one JSON line to the customer's HTTPS endpoint with the options and signature of `Relay.Audit.Checkpointer.Publisher.Https`; `kind: :s3` writes it to the customer's object-locked S3 bucket with the options of `Relay.Audit.Checkpointer.Publisher.S3`.
  """

  @behaviour Relay.Audit.Checkpointer.Publisher

  alias Relay.Audit.Checkpointer.Publisher.Https
  alias Relay.Audit.Checkpointer.Publisher.S3

  # TN-46
  @impl Relay.Audit.Checkpointer.Publisher
  @doc "A customer target is independent of Relay's own operation."
  @spec independent?() :: true
  def independent?, do: true

  @impl Relay.Audit.Checkpointer.Publisher
  @doc "Validates the options of the target's kind."
  @spec validate(keyword()) :: :ok | {:error, String.t()}
  def validate(opts) do
    case Keyword.keyword?(opts) && Keyword.get(opts, :kind) do
      :webhook -> Https.validate(Keyword.delete(opts, :kind))
      :s3 -> S3.validate(Keyword.delete(opts, :kind))
      _ -> {:error, "kind must be :webhook or :s3"}
    end
  end

  # TN-46
  @impl Relay.Audit.Checkpointer.Publisher
  @doc "Publishes a signed checkpoint to the customer's endpoint or bucket."
  @spec publish(Relay.Audit.Checkpointer.Publisher.checkpoint(), keyword()) ::
          :ok | {:error, Relay.Error.t()}
  def publish(checkpoint, opts) do
    case Keyword.pop(opts, :kind) do
      {:webhook, rest} -> Https.post(Https.checkpoint_line(checkpoint), rest)
      {:s3, rest} -> S3.publish(checkpoint, rest)
    end
  end
end
