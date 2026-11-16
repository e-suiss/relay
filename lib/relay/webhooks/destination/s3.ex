defmodule Relay.Webhooks.Destination.S3 do
  @moduledoc """
  The S3 compatible object store destination (WH-17, WH-21): one `PutObject` call, signed with Signature Version 4 and sent through the egress boundary (WH-43). Success is the 2xx answer to the write (WH-18).

  Configuration: `:bucket`, `:region`, `:access_key_id` with the secret access key as `:credential`, and optionally `:prefix` and `:endpoint`, the address of a store other than Amazon S3. A custom endpoint is addressed in path style and obeys the same egress rules as any other address. Without one the bucket is addressed as a host name of the regional S3 host, or in path style when its name holds a dot.

  The destination writes one object for the message it is handed, which is a batch made by `Relay.Webhooks.Batch.prepared/3`: its body is CloudEvents structured JSON lines. The object name is derived from the identifier of the message with `Relay.Webhooks.Batch.object_key/2`, so writing the same batch again writes the same bytes under the same name; the write can be repeated safely. A single event is written as a batch of one line.
  """

  @behaviour Relay.Webhooks.Destination

  alias Relay.Webhooks.Batch
  alias Relay.Webhooks.Destination.Aws
  alias Relay.Webhooks.Destination.Cloud

  @bucket ~r/\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z/
  @prefix ~r/\A[A-Za-z0-9!_.*'()\/-]{0,512}\z/

  # WH-17
  # WH-21
  @impl Relay.Webhooks.Destination
  def deliver(config, prepared, opts) when is_map(config) and is_list(opts) do
    with {:ok, bucket} <- bucket(config),
         {:ok, prefix} <- prefix(config),
         {:ok, region} <- Aws.region(config),
         {:ok, base} <- base(Map.get(config, :endpoint), bucket, region) do
      key = Batch.object_key(prefix, prepared.id)

      request = %{
        method: "PUT",
        url: base <> "/" <> encode(key),
        headers: [{"content-type", Batch.content_type()}],
        body: lines(prepared.body)
      }

      config |> Aws.call("s3", request, opts) |> Cloud.settle()
    end
  end

  defp bucket(config) do
    bucket = Map.get(config, :bucket)

    if is_binary(bucket) and Regex.match?(@bucket, bucket),
      do: {:ok, bucket},
      else: Cloud.invalid("bucket_invalid")
  end

  defp prefix(config) do
    prefix = Map.get(config, :prefix, "") || ""

    if is_binary(prefix) and Regex.match?(@prefix, prefix),
      do: {:ok, prefix},
      else: Cloud.invalid("prefix_invalid")
  end

  defp base(nil, bucket, region) do
    host = Aws.host("s3", region)

    if String.contains?(bucket, "."),
      do: {:ok, "https://" <> host <> "/" <> bucket},
      else: {:ok, "https://" <> bucket <> "." <> host}
  end

  # WH-43
  defp base(endpoint, bucket, _region) when is_binary(endpoint) do
    case URI.new(endpoint) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil} = uri}
      when is_binary(host) and host != "" ->
        path = String.trim_trailing(uri.path || "", "/")
        {:ok, "https://" <> host <> port(uri.port) <> path <> "/" <> bucket}

      _other ->
        Cloud.invalid("endpoint_invalid")
    end
  end

  defp base(_endpoint, _bucket, _region), do: Cloud.invalid("endpoint_invalid")

  defp port(443), do: ""
  defp port(port), do: ":" <> Integer.to_string(port)

  defp encode(key), do: key |> String.split("/") |> Enum.map_join("/", &segment/1)

  defp segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  # WH-21
  defp lines(body), do: if(String.ends_with?(body, "\n"), do: body, else: body <> "\n")
end
