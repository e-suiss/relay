defmodule Relay.Channels.Push.Collapse do
  @moduledoc """
  Subject-based collapse keys (CH-23, C-37). The key is a digest of `{tenant, subject.type, subject.id, message_class}`: notifications about the same subject replace each other, different subjects never mix. Relay fits the key to each platform: APNs `apns-collapse-id` carries the base64url digest (43 bytes, under the 64-byte limit), the Web Push `Topic` its first 32 characters, and FCM, which keeps at most four collapse keys per device, a fixed key per class from the priority table while the subject digest travels in the data payload.
  """

  @typedoc "The subject of a notification."
  @type subject :: %{
          tenant_id: binary(),
          subject_type: String.t(),
          subject_id: String.t(),
          message_class: atom() | String.t()
        }

  @typedoc "The collapse values of every platform."
  @type keys :: %{apns: String.t(), web_push: String.t(), fcm: String.t(), topic: String.t()}

  @domain "relay.collapse.v1"
  @apns_limit 64
  @topic_length 32

  # CH-23
  @doc "The SHA-256 digest of the subject: length-prefixed fields under a domain label, so no two subjects share an encoding."
  @spec digest(subject()) :: <<_::256>>
  def digest(%{tenant_id: tenant, subject_type: type, subject_id: id, message_class: class})
      when is_binary(tenant) and is_binary(type) and is_binary(id) do
    fields = [@domain, tenant, type, id, to_string(class)]
    :crypto.hash(:sha256, Enum.map(fields, &[<<byte_size(&1)::32>>, &1]))
  end

  # CH-23
  @doc "The full collapse key: the base64url digest."
  @spec topic(subject()) :: String.t()
  def topic(subject), do: subject |> digest() |> Base.url_encode64(padding: false)

  # CH-23
  @doc "The APNs `apns-collapse-id`: the full key, 43 bytes."
  @spec apns(subject()) :: String.t()
  def apns(subject), do: topic(subject)

  @doc "The APNs `apns-collapse-id` limit in bytes."
  @spec apns_limit() :: pos_integer()
  def apns_limit, do: @apns_limit

  # CH-23
  @doc "The Web Push `Topic`: the first 32 characters of the full key, URL-safe base64."
  @spec web_push(subject()) :: String.t()
  def web_push(subject), do: subject |> topic() |> binary_part(0, @topic_length)

  # CH-23
  @doc "Every platform's collapse value; `fcm_collapse_key` is the class key of the priority table."
  @spec keys(subject(), String.t()) :: keys()
  def keys(subject, fcm_collapse_key) when is_binary(fcm_collapse_key) do
    topic = topic(subject)

    %{
      apns: topic,
      web_push: binary_part(topic, 0, @topic_length),
      fcm: fcm_collapse_key,
      topic: topic
    }
  end
end
