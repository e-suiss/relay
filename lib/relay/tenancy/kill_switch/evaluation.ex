defmodule Relay.Tenancy.KillSwitch.Evaluation do
  @moduledoc """
  The kill switch decision, a pure function of the snapshot, the message and the time (TN-37). A record is a candidate when it is in force and each of its dimensions matches: scope, channel, target and message class. A record without a message class covers every class except `security` (TN-42). Among the candidates the most restrictive wins: `off`, then a `paused_until` still in the future, then a canary whose threshold the message's bucket reaches; otherwise the message is allowed. Without any snapshot no message is sent (TN-38, INV-43).
  """

  alias Relay.Tenancy.KillSwitch.Record
  alias Relay.Tenancy.KillSwitch.Snapshot

  @type message :: %{
          required(:tenant_id) => Relay.Id.t(),
          required(:environment) => Relay.Environment.t(),
          required(:channel) => String.t() | atom(),
          required(:message_class) => String.t() | atom(),
          required(:notification_id) => Relay.Id.t(),
          optional(:subtenant_id) => Relay.Id.t() | String.t() | nil,
          optional(:campaign_id) => Relay.Id.t() | String.t() | nil,
          optional(:workflow_id) => Relay.Id.t() | String.t() | nil,
          optional(:api_client_id) => Relay.Id.t() | String.t() | nil,
          optional(:sender_id) => Relay.Id.t() | String.t() | nil,
          optional(:provider_account_id) => Relay.Id.t() | String.t() | nil,
          optional(:template_id) => Relay.Id.t() | String.t() | nil
        }
  @type decision :: :allow | {:pause, Relay.Id.t(), String.t()} | {:hold, String.t()}

  @scope_fields [
    subtenant: :subtenant_id,
    campaign: :campaign_id,
    workflow: :workflow_id,
    api_client: :api_client_id,
    sender: :sender_id
  ]

  # TN-37
  # TN-38
  # TN-42
  # INV-43
  @doc "Evaluates the kill switches for one message at `now`."
  @spec evaluate(Snapshot.t() | :unknown, message(), DateTime.t()) :: decision()
  def evaluate(:unknown, _message, _now), do: {:hold, "killswitch.state_unknown"}

  def evaluate(%Snapshot{} = snapshot, message, %DateTime{} = now) do
    refs = for {kind, field} <- @scope_fields, do: {kind, ref(Map.get(message, field))}

    snapshot
    |> Snapshot.candidates(message.tenant_id, message.environment, refs)
    |> Enum.filter(&(Record.in_force?(&1, now) and matches?(&1, message)))
    |> decide(message, now)
  end

  defp matches?(record, message) do
    channel?(record, text(message.channel)) and target?(record, message) and
      class?(record, text(message.message_class))
  end

  defp channel?(%Record{channel: nil}, _channel), do: true
  defp channel?(%Record{channel: channel}, channel), do: true
  defp channel?(%Record{}, _channel), do: false

  defp target?(%Record{target_kind: :all}, _message), do: true

  defp target?(%Record{target_kind: :provider_account, target_ref: ref}, message),
    do: ref(Map.get(message, :provider_account_id)) == ref

  defp target?(%Record{target_kind: :template, target_ref: ref}, message),
    do: ref(Map.get(message, :template_id)) == ref

  defp class?(%Record{message_class: nil}, class), do: class != "security"
  defp class?(%Record{message_class: class}, class), do: true
  defp class?(%Record{}, _class), do: false

  defp decide([], _message, _now), do: :allow

  defp decide(candidates, message, now) do
    with :none <- off(candidates),
         :none <- paused(candidates, now),
         :none <- canary(candidates, message) do
      :allow
    end
  end

  defp off(candidates) do
    case Enum.filter(candidates, &(&1.state == :off)) do
      [] ->
        :none

      offs ->
        oldest = Enum.min_by(offs, &{DateTime.to_unix(&1.created_at, :microsecond), &1.id})
        {:pause, oldest.id, "killswitch.off"}
    end
  end

  defp paused(candidates, now) do
    case Enum.filter(candidates, &paused_at?(&1, now)) do
      [] -> :none
      paused -> {:pause, Enum.max_by(paused, &until_key/1).id, "killswitch.paused_until"}
    end
  end

  defp paused_at?(%Record{state: :paused_until, paused_until: nil}, _now), do: true

  defp paused_at?(%Record{state: :paused_until, paused_until: until}, now),
    do: DateTime.compare(until, now) == :gt

  defp paused_at?(%Record{}, _now), do: false

  defp until_key(%Record{paused_until: nil, id: id}), do: {1, 0, id}

  defp until_key(%Record{paused_until: until, id: id}),
    do: {0, DateTime.to_unix(until, :microsecond), id}

  defp canary(candidates, message) do
    case Enum.filter(candidates, &(&1.state == :canary)) do
      [] ->
        :none

      canaries ->
        record = Enum.min_by(canaries, &{&1.canary_percent, &1.id})

        if Relay.Jitter.canary?(
             message.tenant_id,
             message.environment,
             message.notification_id,
             record.canary_percent
           ),
           do: :none,
           else: {:pause, record.id, "killswitch.canary"}
    end
  end

  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value) when is_binary(value), do: value

  defp ref(nil), do: nil
  defp ref(<<_::128>> = id), do: Relay.Id.to_string(id)
  defp ref(value) when is_binary(value), do: value
end
