defmodule Relay.Channels.Outcome do
  @moduledoc """
  The normalized outcome of one provider call (CH-7, CH-8, INV-46). An adapter result becomes an attempt state, one of the eight failure classes with its condition, the provider's raw code and the event code of the channel's evidence row; group and detail are both kept, so the ledger holds the normalized class next to the raw code (§12.2.2).

    * An acceptance is `succeeded` with the `accepted` event.
    * A rejection is `failed` with the class, condition and event code of the adapter's mapping. A code without a mapping is `unknown`, flagged `unknown_code?` so the caller raises the `provider.unknown_code` event and the alarm; nothing is guessed. A provider "success" for a recipient it suppresses is kept apart as `suppressed?` (CH-8).
    * A request that never reached the provider is `failed` and `transient` (`server_error`, raw code `transport:<reason>`), so it is retried.
    * A request whose answer never came is `unknown` with the `uncertain` event (`transient`, `timeout`, raw code `uncertain:<reason>`); `Relay.Channels.Ambiguity` decides what follows (T-28).

  Every action is a function of the class only (`actions/1`): retry, channel fallback, target cleanup, subscriber suppression and the alarm. An outcome whose event code has no evidence row of the provider's channel is refused (DS-10).
  """

  alias Relay.ChannelDeclarations
  alias Relay.Channels.Adapter

  @classes ~w(transient permanent_target permanent_content policy quota auth sender_config unknown)

  @enforce_keys [:state, :event_code]
  defstruct [
    :state,
    :event_code,
    failure_class: nil,
    condition: nil,
    raw_code: nil,
    status: nil,
    retry_after_ms: nil,
    timestamp: nil,
    provider_message_id: nil,
    delivery_rank: :accepted,
    unknown_code?: false,
    suppressed?: false,
    followups: [],
    detail: %{}
  ]

  @type state :: :succeeded | :failed | :unknown
  @type t :: %__MODULE__{
          state: state(),
          event_code: String.t(),
          failure_class: String.t() | nil,
          condition: String.t() | nil,
          raw_code: String.t() | nil,
          status: non_neg_integer() | nil,
          retry_after_ms: non_neg_integer() | nil,
          timestamp: DateTime.t() | nil,
          provider_message_id: String.t() | nil,
          delivery_rank: :accepted | :delivered,
          unknown_code?: boolean(),
          suppressed?: boolean(),
          followups: [Adapter.followup()],
          detail: map()
        }

  @type retry :: :backoff | :never | :until_quota | :after_refresh | :limited
  @type target :: :keep | :disable | :preference
  @type actions :: %{
          retry: retry(),
          fallback: boolean(),
          target: target(),
          suppress_subscriber: boolean(),
          alarm: boolean()
        }

  @doc "The eight failure classes (CH-7)."
  @spec classes() :: [String.t(), ...]
  def classes, do: @classes

  # CH-7
  # CH-8
  # DS-10
  # INV-46
  @doc "Normalizes the result of a provider call against the provider's declaration; `{:error, :unknown_event}` when the event code has no evidence row on the channel."
  @spec normalize(ChannelDeclarations.t(), String.t(), String.t(), Adapter.result()) ::
          {:ok, t()} | {:error, :unknown_event}
  def normalize(%ChannelDeclarations{} = declarations, provider, channel, result) do
    outcome = from_result(declarations, provider, result)

    case ChannelDeclarations.evidence(declarations, provider, channel, outcome.event_code) do
      {:ok, _row} -> {:ok, outcome}
      {:error, :unknown_event} -> {:error, :unknown_event}
    end
  end

  defp from_result(_declarations, _provider, {:accepted, info}) do
    %__MODULE__{
      state: :succeeded,
      event_code: "accepted",
      provider_message_id: Map.get(info, :provider_message_id),
      delivery_rank: Map.get(info, :delivery_rank, :accepted),
      followups: Map.get(info, :followups, []),
      detail: Map.get(info, :detail, %{})
    }
  end

  defp from_result(declarations, provider, {:rejected, %{code: code} = raw}) do
    base = %__MODULE__{
      state: :failed,
      event_code: "rejected",
      raw_code: code,
      status: Map.get(raw, :status),
      retry_after_ms: Map.get(raw, :retry_after_ms),
      timestamp: Map.get(raw, :timestamp),
      detail: Map.get(raw, :detail, %{})
    }

    case ChannelDeclarations.mapping(declarations, provider, code) do
      {:ok, mapping} ->
        %{
          base
          | failure_class: mapping["class"],
            condition: mapping["condition"],
            event_code: mapping["event_code"],
            suppressed?: mapping["suppressed_success"] == true
        }

      :unmapped ->
        %{base | failure_class: "unknown", unknown_code?: true}
    end
  end

  defp from_result(_declarations, _provider, {:not_sent, reason}) do
    %__MODULE__{
      state: :failed,
      event_code: "rejected",
      failure_class: "transient",
      condition: "server_error",
      raw_code: raw_code("transport:", reason)
    }
  end

  defp from_result(_declarations, _provider, {:uncertain, reason}) do
    %__MODULE__{
      state: :unknown,
      event_code: "uncertain",
      failure_class: "transient",
      condition: "timeout",
      raw_code: raw_code("uncertain:", reason)
    }
  end

  defp raw_code(prefix, reason), do: String.slice(prefix <> reason, 0, 128)

  # CH-7
  # CH-11
  # INV-14
  # L-48
  @doc """
  The actions of a failure class, derived from the class only (§12.2.1): whether and how it is retried, whether it moves the channel fallback, what happens to the address or token (`:disable` is the immediate soft disable of CH-11, `:preference` a preference or suppression record), whether the subscriber is suppressed (never for `sender_config`) and whether it raises an alarm.
  """
  @spec actions(String.t()) :: actions()
  def actions("transient"), do: actions(:backoff, false, :keep, false)
  def actions("permanent_target"), do: actions(:never, true, :disable, false)
  def actions("permanent_content"), do: actions(:never, true, :keep, true)
  def actions("policy"), do: actions(:never, true, :preference, false)
  def actions("quota"), do: actions(:until_quota, false, :keep, false)
  def actions("auth"), do: actions(:after_refresh, false, :keep, false)
  def actions("sender_config"), do: actions(:never, true, :keep, false)
  def actions("unknown"), do: actions(:limited, false, :keep, true)

  defp actions(retry, fallback, target, alarm) do
    %{
      retry: retry,
      fallback: fallback,
      target: target,
      suppress_subscriber: target == :preference,
      alarm: alarm
    }
  end
end
