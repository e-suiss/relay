defmodule Relay.Channels.Email.Event do
  @moduledoc """
  An e-mail event a provider reported after the send (CH-39, CH-47): a delivery, a bounce, a deferral, a complaint, a provider-side rejection, an engagement event or one Relay ignores. Each ESP adapter parses its own event payloads into this shape, after the payload's signature was verified on the raw body.

    * `type`: `:delivered`, `:bounced`, `:deferred`, `:complained`, `:rejected`, `:engagement` or `:ignored`.
    * `code`: the provider's own event code, such as Postmark's `HardBounce` or SES's `Permanent/General`; `classify/3` reads its mapping as `event:<code>` in the adapter's errors map, so the meaning of a provider code is data (CH-7, CH-18).
    * `delivery_id`: the delivery the event belongs to, read from the correlation value Relay sent (`relay_delivery_id`) or from the `Message-ID` Relay wrote (`<delivery id@domain>`); `nil` when the event names neither.
    * `recipient` (redacted), `provider_message_id`, `id` (the provider's event identifier, for deduplication), `occurred_at`, and for a bounce the SMTP `status` and the redacted `diagnostic`.
  """

  alias Relay.ChannelDeclarations
  alias Relay.Channels.Email.Bounce
  alias Relay.Channels.Email.StatusCode
  alias Relay.Redacted

  @correlation "relay_delivery_id"
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  @message_id ~r/\A<?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})@[^>]+>?\z/i
  @kinds %{
    "permanent_target" => :hard,
    "transient" => :soft,
    "sender_config" => :sender_config,
    "permanent_content" => :policy,
    "policy" => :policy,
    "quota" => :soft,
    "auth" => :sender_config,
    "unknown" => :unknown
  }

  @type type ::
          :delivered | :bounced | :deferred | :complained | :rejected | :engagement | :ignored

  @enforce_keys [:provider, :type, :code]
  defstruct [
    :provider,
    :type,
    :code,
    id: nil,
    delivery_id: nil,
    provider_message_id: nil,
    recipient: nil,
    occurred_at: nil,
    status: nil,
    diagnostic: nil
  ]

  @type t :: %__MODULE__{
          provider: String.t(),
          type: type(),
          code: String.t(),
          id: String.t() | nil,
          delivery_id: Relay.Id.t() | nil,
          provider_message_id: String.t() | nil,
          recipient: Redacted.t() | nil,
          occurred_at: DateTime.t() | nil,
          status: String.t() | nil,
          diagnostic: Redacted.t() | nil
        }

  @doc "The name of the correlation value every ESP adapter sends with a message: the delivery identifier as text."
  @spec correlation_key() :: String.t()
  def correlation_key, do: @correlation

  # CH-47
  @doc "The delivery identifier named by a correlation value or by a `Message-ID` Relay wrote; `nil` for anything else."
  @spec delivery_id(String.t() | nil) :: Relay.Id.t() | nil
  def delivery_id(value) when is_binary(value) do
    value = String.trim(value)

    text =
      cond do
        value =~ @uuid -> value
        match = Regex.run(@message_id, value, capture: :all_but_first) -> hd(match)
        true -> nil
      end

    case text && Relay.Id.parse(text) do
      {:ok, id} -> id
      _other -> nil
    end
  end

  def delivery_id(_value), do: nil

  @doc "The first delivery identifier among several candidate values."
  @spec first_delivery_id([String.t() | nil]) :: Relay.Id.t() | nil
  def first_delivery_id(values) when is_list(values), do: Enum.find_value(values, &delivery_id/1)

  # CH-39
  # CH-77
  # CH-8
  @doc """
  Classifies an event into a bounce result of `Relay.Channels.Email.Bounce`. A delivery is `:delivered` and a complaint a `complaint`. A bounce, a deferral or a rejection whose `status` or `diagnostic` carries an SMTP status code is classified against the `email_bounce_codes` content `table`; otherwise, and when that gives `unknown`, the class the adapter's errors map gives `event:<code>` decides. A code without a mapping is `unknown`, never guessed. Engagement and ignored events are `nil`.
  """
  @spec classify(t(), ChannelDeclarations.t(), map()) :: Bounce.t() | nil
  def classify(%__MODULE__{type: :delivered}, _declarations, _table), do: outcome(:delivered)

  def classify(%__MODULE__{type: :complained} = event, _declarations, _table),
    do: %{outcome(:complaint) | rule: "event:" <> event.code}

  def classify(%__MODULE__{type: type} = event, declarations, table)
      when type in [:bounced, :deferred, :rejected] do
    action = if type == :deferred, do: "delayed", else: "failed"

    recipient = %{
      final_recipient: event.recipient,
      original_recipient: nil,
      action: action,
      status: status(event.status),
      status_text: event.status,
      diagnostic_type: nil,
      diagnostic: event.diagnostic,
      remote_mta: nil,
      will_retry_until: nil
    }

    case Bounce.classify(recipient, table) do
      %{kind: :unknown} -> mapped(event, declarations, type)
      result -> result
    end
  end

  def classify(%__MODULE__{}, _declarations, _table), do: nil

  defp mapped(_event, _declarations, :deferred), do: outcome(:delayed)

  defp mapped(event, declarations, _type) do
    code = "event:" <> event.code

    kind =
      case ChannelDeclarations.mapping(declarations, event.provider, code) do
        {:ok, row} -> Map.fetch!(@kinds, row["class"])
        :unmapped -> :unknown
      end

    kind |> outcome() |> Map.merge(%{status: event.status, rule: code})
  end

  defp outcome(kind) do
    {class, suppression, reputation} = effects(kind)

    %{
      kind: kind,
      failure_class: class,
      suppression: suppression,
      reputation: reputation,
      status: nil,
      rule: nil
    }
  end

  defp effects(:hard), do: {"permanent_target", "hard_bounce", :bounce}
  defp effects(:soft), do: {"transient", "soft_bounce", nil}
  defp effects(:complaint), do: {"policy", "complaint", :complaint}
  defp effects(:sender_config), do: {"sender_config", nil, nil}
  defp effects(:policy), do: {"permanent_content", nil, :bounce}
  defp effects(:unknown), do: {"unknown", nil, nil}
  defp effects(_outcome), do: {nil, nil, nil}

  defp status(nil), do: nil

  defp status(text) do
    case StatusCode.parse(text) do
      {:ok, status} -> status
      :error -> nil
    end
  end

  @doc "Wraps a provider value as a redacted recipient or diagnostic; `nil` stays `nil`."
  @spec redact(term()) :: Redacted.t() | nil
  def redact(value) when is_binary(value) and value != "", do: Redacted.wrap(value)
  def redact(_value), do: nil

  @doc "Parses an ISO 8601 or Unix seconds timestamp of a provider event; `nil` when it is neither."
  @spec timestamp(term()) :: DateTime.t() | nil
  def timestamp(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  def timestamp(value) when is_float(value), do: value |> trunc() |> timestamp()

  def timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  def timestamp(_value), do: nil
end
