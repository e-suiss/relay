defmodule Relay.Channels.Whatsapp.Status do
  @moduledoc """
  The message status webhooks of the WhatsApp Cloud API (CH-60, DS-12).

    * A status (`sent`, `delivered`, `read`, `failed`) is normalized into an event of the provider's evidence table by `normalize/1`, the single place a status becomes an event, so the ingestion entry point can change without touching the parsing.
    * Duplicate and out-of-order statuses are expected by design: the deduplication key is `wamid + status + timestamp` (`dedup_key/1`), and transitions are monotonic: `sent` → `delivered` → `read`; a lower status after a higher one changes nothing, and `failed` after `delivered` is a conflict, not a regression (§14).
    * The whole `pricing` object of a status is kept as it came; `pricing.type` is the source of truth of the cost (CH-60, CH-18).
    * When messages to one recipient must stay in order, the next one waits for the `delivered` event of the previous one (`ordering/1`).
  """

  alias Relay.Channels.Whatsapp.Message

  @ranks %{"sent" => 1, "delivered" => 2, "read" => 3}
  @statuses ~w(sent delivered read failed)

  @type event :: %{
          provider_message_id: String.t(),
          event_code: String.t(),
          occurred_at: DateTime.t(),
          recipient: String.t() | nil,
          correlation: {Relay.Id.t(), pos_integer()} | nil,
          raw_code: String.t() | nil,
          errors: [map()],
          pricing: map() | nil,
          conversation: map() | nil,
          dedup_key: String.t()
        }

  @doc "The status values Meta reports that Relay records."
  @spec statuses() :: [String.t(), ...]
  def statuses, do: @statuses

  # CH-60
  @doc "The deduplication key of a status: its message id, status and timestamp."
  @spec dedup_key(map()) :: String.t()
  def dedup_key(%{"id" => id, "status" => status, "timestamp" => timestamp}),
    do: Enum.join([id, status, to_string(timestamp)], ":")

  # CH-60
  # DS-12
  @doc "Normalizes one entry of `statuses`; an unknown status or an entry without message id or timestamp is `:ignored`."
  @spec normalize(map()) :: {:ok, event()} | :ignored
  def normalize(%{"id" => id, "status" => status, "timestamp" => ts} = entry)
      when is_binary(id) and id != "" and status in @statuses do
    with {:ok, at} <- timestamp(ts) do
      errors = list(entry["errors"])

      {:ok,
       %{
         provider_message_id: id,
         event_code: status,
         occurred_at: at,
         recipient: string(entry["recipient_id"]),
         correlation: correlation(entry["biz_opaque_callback_data"]),
         raw_code: raw_code(status, errors),
         errors: errors,
         pricing: map(entry["pricing"]),
         conversation: map(entry["conversation"]),
         dedup_key: dedup_key(entry)
       }}
    end
  end

  def normalize(_entry), do: :ignored

  defp raw_code("failed", [%{"code" => code} | _]) when is_integer(code),
    do: Integer.to_string(code)

  defp raw_code("failed", [%{"code" => code} | _]) when is_binary(code), do: code
  defp raw_code("failed", _errors), do: "failed"
  defp raw_code(_status, _errors), do: nil

  defp correlation(value) do
    case Message.parse_correlation(value) do
      {:ok, delivery_id, attempt_no} -> {delivery_id, attempt_no}
      :error -> nil
    end
  end

  # CH-60
  @doc "Whether a status moves a message forward from the highest status recorded for it: `:apply`, `:stale` for a status at or below it, `:conflict` for a failure after delivery."
  @spec transition(String.t() | nil, String.t()) :: :apply | :stale | :conflict
  def transition(current, "failed") do
    if rank(current) >= @ranks["delivered"], do: :conflict, else: :apply
  end

  def transition("failed", _status), do: :stale

  def transition(current, status) when is_map_key(@ranks, status) do
    if @ranks[status] > rank(current), do: :apply, else: :stale
  end

  def transition(_current, _status), do: :stale

  defp rank(nil), do: 0
  defp rank(status), do: Map.get(@ranks, status, 0)

  # CH-60
  @doc "Whether the next message to the same recipient may go when messages must stay in order: only after the previous one is delivered (or read); a failed previous message no longer holds the order."
  @spec ordering(String.t() | nil) :: :ready | :wait
  def ordering(previous) when previous in ["delivered", "read", "failed"], do: :ready
  def ordering(_previous), do: :wait

  @doc "Parses a Meta Unix timestamp in seconds, given as a string or an integer."
  @spec timestamp(term()) :: {:ok, DateTime.t()} | :ignored
  def timestamp(value) when is_integer(value) and value >= 0 do
    case DateTime.from_unix(value) do
      {:ok, at} -> {:ok, at}
      {:error, _reason} -> :ignored
    end
  end

  def timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} -> timestamp(seconds)
      _other -> :ignored
    end
  end

  def timestamp(_value), do: :ignored

  defp list(value) when is_list(value), do: Enum.filter(value, &is_map/1)
  defp list(_value), do: []

  defp map(value) when is_map(value), do: value
  defp map(_value), do: nil

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil
end
