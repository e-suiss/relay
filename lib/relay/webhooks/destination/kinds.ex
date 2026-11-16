defmodule Relay.Webhooks.Destination.Kinds do
  @moduledoc """
  The destination kinds of an endpoint and the module that delivers to each (WH-17). The names are the `kind` values of an endpoint's destination; every module implements `Relay.Webhooks.Destination`.
  """

  alias Relay.Webhooks.Destination

  @modules %{
    "https" => Destination.Https,
    "kafka" => Destination.Kafka,
    "nats_jetstream" => Destination.NatsJetstream,
    "rabbitmq" => Destination.Rabbitmq,
    "aws_sqs" => Destination.AwsSqs,
    "aws_sns" => Destination.AwsSns,
    "aws_eventbridge" => Destination.AwsEventbridge,
    "gcp_pubsub" => Destination.GcpPubsub,
    "azure_service_bus" => Destination.AzureServiceBus,
    "azure_event_grid" => Destination.AzureEventGrid,
    "s3" => Destination.S3
  }

  # WH-17
  @doc "Every destination kind."
  @spec all() :: [String.t(), ...]
  def all, do: Enum.sort(Map.keys(@modules))

  # WH-17
  @doc "The module that delivers to a destination kind."
  @spec module(term()) :: {:ok, module()} | :error
  def module(kind), do: Map.fetch(@modules, kind)
end
