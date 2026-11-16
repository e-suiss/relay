defmodule Relay.Webhooks.Destination.AwsEventbridge do
  @moduledoc """
  The Amazon EventBridge destination (WH-17): one `PutEvents` call with one entry, signed with Signature Version 4 and sent to the regional EventBridge host through the egress boundary (WH-43). EventBridge has no mutual TLS.

  Configuration: `:event_bus_arn`, `:region` and the credentials of `Relay.Webhooks.Destination.Aws`.

  The entry carries the whole event in structured mode as its `Detail`, the `source` of the event as `Source` and its `type` as `DetailType` (WH-8 (3)). EventBridge has no deduplication identifier of its own; the consumer deduplicates on the CloudEvents `id` inside the detail (WH-18).

  `PutEvents` answers 200 even when it did not take the entry, so success is a 200 answer whose `FailedEntryCount` is 0 (WH-18). A failed entry is classified by its error code: throttling and internal errors mean the bus is not available now, an access error that the credentials are not accepted, and anything else that the bus refused the event. An answer that cannot be read is retried.
  """

  @behaviour Relay.Webhooks.Destination

  alias Relay.Webhooks.Destination.Aws
  alias Relay.Webhooks.Destination.Cloud

  @headers [
    {"content-type", "application/x-amz-json-1.1"},
    {"x-amz-target", "AWSEvents.PutEvents"}
  ]
  @code ~r/\A[A-Za-z0-9]{1,64}\z/
  @unavailable ~w(ThrottlingException InternalFailure InternalException ServiceUnavailable)
  @credentials ~w(AccessDeniedException NotAuthorized UnrecognizedClientException)

  # WH-17
  # WH-18
  @impl Relay.Webhooks.Destination
  def deliver(config, prepared, opts) when is_map(config) and is_list(opts) do
    with {:ok, bus} <- bus(config),
         {:ok, region} <- Aws.region(config) do
      body = Jason.encode!(%{"Entries" => [entry(bus, prepared)]})
      url = "https://" <> Aws.host("events", region) <> "/"
      request = %{method: "POST", url: url, headers: @headers, body: body}
      config |> Aws.call("events", request, opts) |> verdict()
    end
  end

  defp bus(config) do
    bus = Map.get(config, :event_bus_arn)
    if Aws.arn?(bus), do: {:ok, bus}, else: Cloud.invalid("event_bus_arn_invalid")
  end

  # WH-8 (3)
  defp entry(bus, prepared) do
    %{
      "EventBusName" => bus,
      "Source" => source(prepared),
      "DetailType" => prepared.type,
      "Detail" => prepared.body
    }
  end

  defp source(%{attributes: attributes}) do
    case List.keyfind(attributes, "source", 0) do
      {"source", source} -> source
      nil -> ""
    end
  end

  # WH-18
  defp verdict({:ok, %{status: 200, truncated: false} = response}) do
    case Jason.decode(response.body) do
      {:ok, %{"FailedEntryCount" => 0}} -> {:ok, Cloud.receipt(response)}
      {:ok, %{"Entries" => [%{"ErrorCode" => code} | _rest]}} -> {:error, failed(code, response)}
      _unreadable -> {:error, Cloud.failure(:protocol, "response_unreadable", response)}
    end
  end

  defp verdict({:ok, %{status: 200} = response}),
    do: {:error, Cloud.failure(:protocol, "response_unreadable", response)}

  defp verdict(answer), do: Cloud.settle(answer)

  defp failed(code, response) do
    if is_binary(code) and Regex.match?(@code, code),
      do: Cloud.failure(entry_class(code), "eventbridge_" <> code, response),
      else: Cloud.failure(:rejected, "eventbridge_entry_failed", response)
  end

  defp entry_class(code) when code in @unavailable, do: :unavailable
  defp entry_class(code) when code in @credentials, do: :credentials
  defp entry_class(_code), do: :rejected
end
