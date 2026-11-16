defmodule Relay.Webhooks.DeliveryLog do
  @moduledoc """
  The delivery log as it is read (WH-10, WH-30): pages of messages, the events an endpoint missed, the attempts of a message and one attempt with its answer. Messages and dead letters are kept for the delivery log's retention and the answers of attempts for the shorter response body retention; the tenant's `webhook.retention` setting can only lower either, down to the contract's minimum (WH-52).

  The answer of an attempt is kept sealed under the tenant's data key and may hold personal data. It is opened only when one attempt is read, outside any transaction, and comes back redacted; an answer whose retention ended is not returned, whether or not the sweep has erased it yet, and neither is one that no longer opens. No secret is ever part of an attempt (WH-19).
  """

  alias Relay.Scope
  alias Relay.Webhooks.EngineStore
  alias Relay.Webhooks.LogStore
  alias Relay.Webhooks.Settings

  @response_field {"webhook_attempts", "response_ct"}
  @sealed ~w(response_ct response_key_id response_truncated response_erased_at)

  @type id :: Relay.Id.t()
  @type cursor :: map() | nil
  @type result(value) :: {:ok, value} | {:error, term()}

  # WH-30 (3)
  # API-56
  @doc "A page of the messages of the scope, newest first; see `Relay.Webhooks.LogStore.messages/3`."
  @spec messages(Scope.t(), map(), cursor(), pos_integer()) :: result([map()])
  def messages(%Scope{} = scope, filters, cursor, limit),
    do: read(scope, fn -> LogStore.messages(filters, cursor, limit) end)

  # WH-30 (2)
  # WH-37
  # API-56
  @doc "A page of the events an endpoint missed, newest first: its messages in a terminal state other than `delivered` and those held while it was disabled. `:not_found` for an unknown endpoint."
  @spec missed(Scope.t(), id(), map(), cursor(), pos_integer()) :: result(:not_found | [map()])
  def missed(%Scope{} = scope, endpoint_id, filters, cursor, limit) do
    filters = Map.merge(filters, %{endpoint_id: endpoint_id, missed: true})

    read(scope, fn ->
      if LogStore.endpoint(endpoint_id),
        do: LogStore.messages(filters, cursor, limit),
        else: :not_found
    end)
  end

  # WH-10
  # API-56
  @doc "A page of the attempts of a message in attempt order, without their answers; `:not_found` for an unknown message."
  @spec attempts(Scope.t(), id(), cursor(), pos_integer()) :: result(:not_found | [map()])
  def attempts(%Scope{} = scope, message_id, cursor, limit) do
    read(scope, fn ->
      if LogStore.message(message_id),
        do: LogStore.attempts(message_id, cursor, limit),
        else: :not_found
    end)
  end

  # WH-10
  # WH-19
  # WH-30
  @doc "Reads one attempt of a message with, under `\"response\"`, its answer as `%{body: redacted, truncated: boolean}`, or `nil` when there is none, its retention ended or it no longer opens; the retention is measured at `now`. `:not_found` for an unknown message and `nil` for an attempt the message does not have. Runs outside any transaction."
  @spec attempt(Scope.t(), id(), id(), DateTime.t()) :: result(:not_found | map() | nil)
  def attempt(%Scope{} = scope, message_id, attempt_id, now \\ Relay.Clock.utc_now()) do
    with {:ok, %{} = row} <- read(scope, fn -> stored(message_id, attempt_id, now) end) do
      {:ok, row |> Map.drop(@sealed) |> Map.put("response", response(scope, row))}
    end
  end

  defp stored(message_id, attempt_id, now) do
    cond do
      LogStore.message(message_id) == nil -> :not_found
      row = LogStore.attempt(message_id, attempt_id) -> kept(row, kept_since(:responses, now))
      true -> nil
    end
  end

  defp kept(%{"created_at" => created_at} = row, since),
    do: Map.put(row, "kept", DateTime.compare(created_at, since) == :gt)

  defp response(_scope, %{"response_ct" => nil}), do: nil
  defp response(_scope, %{"kept" => false}), do: nil

  defp response(scope, %{"response_ct" => ct, "response_key_id" => key_id} = row) do
    case Settings.sealer().open(scope, @response_field, key_id, ct) do
      {:ok, body} -> %{body: body, truncated: row["response_truncated"]}
      {:error, _error} -> nil
    end
  end

  # WH-30
  # WH-52
  @doc "The time since which the delivery log is kept at `now`, inside the caller's scoped transaction: for `:messages` the messages, dead letters and event payloads, for `:responses` the answers of attempts. It is the contract's retention or the shorter one of the tenant's `webhook.retention` setting."
  @spec kept_since(:messages | :responses, DateTime.t()) :: DateTime.t()
  def kept_since(kind, %DateTime{} = now) do
    defaults = Settings.retention()
    setting = EngineStore.retention_setting() || %{}

    days =
      case kind do
        :messages -> days(setting["messages_days"], defaults.messages_days, defaults)
        :responses -> days(setting["response_body_days"], defaults.response_body_days, defaults)
      end

    DateTime.add(now, -days * 86_400, :second)
  end

  defp days(value, default, %{min_days: min}) when is_integer(value),
    do: value |> max(min) |> min(default)

  defp days(_unset, default, _defaults), do: default

  defp read(scope, fun), do: EngineStore.in_scope(scope, fn _status -> fun.() end)
end
