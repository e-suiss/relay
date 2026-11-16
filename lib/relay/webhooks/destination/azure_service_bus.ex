defmodule Relay.Webhooks.Destination.AzureServiceBus do
  @moduledoc """
  The Azure Service Bus destination (WH-17): one message sent to a queue or topic over the Service Bus HTTPS API, through the egress boundary (WH-43). Success is the 2xx answer, which Service Bus gives once the message is stored (WH-18).

  Configuration: `:namespace` (the fully qualified host name), `:entity` (the queue or topic), `:cloudevents_mode` (`"binary"` by default) and either `:managed_identity_client_id` or the connection string of the namespace as `:credential`.

  With a connection string the request carries a shared access signature made from the key name and the key of the string, for this entity alone and valid for `:credential_ttl_s` seconds; a string that already holds a shared access signature is used as it is. The address inside the string is ignored: the request always goes to `:namespace`. With a managed identity the request carries the bearer token of `Relay.Webhooks.Destination.Azure`. Neither the string, the key nor a token appears in a failure or in a receipt (WH-19).

  The CloudEvents `id` is the `MessageId` of the message, the key duplicate detection works on (WH-18), and the ordering key of the event is its `SessionId`, so the events of one subject are one session (WH-20 (3)). In binary mode the body is `data` and the context attributes are application properties with the `cloudEvents_` prefix of the CloudEvents AMQP binding, written as HTTP headers and therefore percent-encoded like the headers of the HTTP binding. In structured mode the body is the whole event (WH-8 (3)).
  """

  @behaviour Relay.Webhooks.Destination

  alias Relay.Redacted
  alias Relay.Webhooks.Destination.Azure
  alias Relay.Webhooks.Destination.Cloud
  alias Relay.Webhooks.Envelope

  @namespace ~r/\A[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?\z/
  @segment ~r/\A[\x21-\x7E]+\z/
  @resource "https://servicebus.azure.net"

  # WH-17
  # WH-18
  @impl Relay.Webhooks.Destination
  def deliver(config, prepared, opts) when is_map(config) and is_list(opts) do
    with {:ok, resource} <- resource(config),
         {:ok, mode} <- Cloud.mode(config, :binary),
         {:ok, authorization} <- authorization(config, resource, opts) do
      request = %{
        method: "POST",
        url: resource <> "/messages",
        headers: authorization ++ headers(mode, prepared),
        body: body(mode, prepared)
      }

      opts |> Cloud.request(request) |> Cloud.settle()
    end
  end

  defp resource(config) do
    namespace = Map.get(config, :namespace)
    segments = segments(Map.get(config, :entity))

    if is_binary(namespace) and Regex.match?(@namespace, namespace) and segments != [] do
      path = Enum.map_join(segments, "/", &encode/1)
      {:ok, "https://" <> String.downcase(namespace, :ascii) <> "/" <> path}
    else
      Cloud.invalid("entity_invalid")
    end
  end

  defp segments(entity) when is_binary(entity) and byte_size(entity) <= 260 do
    segments = String.split(entity, "/")
    if Enum.all?(segments, &segment?/1), do: segments, else: []
  end

  defp segments(_entity), do: []

  defp segment?(segment), do: Regex.match?(@segment, segment) and segment not in [".", ".."]

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  # WH-8 (3)
  defp body(:binary, prepared), do: prepared.data
  defp body(:structured, prepared), do: prepared.body

  defp headers(:structured, prepared),
    do: [{"content-type", prepared.content_type}, broker_properties(prepared)]

  defp headers(:binary, prepared) do
    properties =
      for {"ce-" <> name, value} <- Envelope.binary_headers(prepared.attributes, :http) do
        {"cloudEvents_" <> name, value}
      end

    fixed = [{"content-type", Cloud.data_content_type(prepared)}, broker_properties(prepared)]
    fixed ++ properties
  end

  # WH-18
  # WH-20 (3)
  defp broker_properties(%{id: id, partition_key: key}) do
    properties = session(%{"MessageId" => id}, key)
    {"brokerproperties", Jason.encode!(properties, escape: :unicode_safe)}
  end

  defp session(properties, nil), do: properties
  defp session(properties, key), do: Map.put(properties, "SessionId", key)

  # WH-17
  defp authorization(config, resource, opts) do
    client_id = Map.get(config, :managed_identity_client_id)
    credential = Map.get(config, :credential)

    cond do
      is_binary(client_id) -> Azure.bearer(client_id, @resource, opts)
      Redacted.redacted?(credential) -> shared_access(credential, resource, opts)
      true -> Cloud.invalid("credentials_missing")
    end
  end

  # WH-19
  defp shared_access(credential, resource, opts) do
    case fields(Redacted.expose(credential)) do
      %{"SharedAccessSignature" => "SharedAccessSignature " <> _rest = signature} ->
        {:ok, [{"authorization", signature}]}

      %{"SharedAccessKeyName" => name, "SharedAccessKey" => key} when name != "" and key != "" ->
        {:ok, [{"authorization", signature(name, key, resource, opts)}]}

      _other ->
        Cloud.invalid("connection_string_invalid")
    end
  end

  defp fields(connection) when is_binary(connection) do
    for field <- String.split(connection, ";", trim: true),
        [name, value] <- [String.split(field, "=", parts: 2)],
        into: %{},
        do: {String.trim(name), value}
  end

  defp fields(_connection), do: %{}

  defp signature(name, key, resource, opts) do
    expiry = DateTime.to_unix(Cloud.now(opts)) + Keyword.fetch!(opts, :credential_ttl_s)
    scope = URI.encode_www_form(resource)
    to_sign = scope <> "\n" <> Integer.to_string(expiry)
    mac = Base.encode64(:crypto.mac(:hmac, :sha256, key, to_sign))

    IO.iodata_to_binary([
      "SharedAccessSignature sr=",
      scope,
      "&sig=",
      URI.encode_www_form(mac),
      "&se=",
      Integer.to_string(expiry),
      "&skn=",
      URI.encode_www_form(name)
    ])
  end
end
