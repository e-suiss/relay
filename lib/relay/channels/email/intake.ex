defmodule Relay.Channels.Email.Intake do
  @moduledoc """
  What a verified provider e-mail event leads to (CH-39, CH-40, CH-41, CH-8), as a pure plan the intake applies; nothing here writes. An event (`Relay.Channels.Email.Event`) is classified first (`Relay.Channels.Email.Event.classify/3`), and its kind decides:

  | Kind | Subscriber | Reputation counter | Other | Evidence |
  |---|---|---|---|---|
  | `hard` | `hard_bounce` suppression, without end | bounce | — | `bounced` |
  | `soft` | counted; a timed `soft_bounce` suppression at the window's count | — | — | `rejected` |
  | `complaint` | `complaint` suppression, without end | complaint | — | `complained` |
  | `sender_config` | never suppressed | — | the sending domain's event and the `{tenant, provider}` breaker | `rejected` |
  | `policy` | never suppressed | bounce | — | `rejected` |
  | `content` | never suppressed | — | — | `rejected` |
  | `unknown` | never suppressed | — | `provider.unknown_code` and an alarm | `rejected` |
  | `delivered` | — | delivered | — | `delivered` |

  A deferral, an engagement event and an ignored event lead to nothing. A soft bounce becomes a timed suppression only through `soft_bounce/3` with the address's earlier soft bounces (CH-40); a permanent bounce is never timed.
  """

  alias Relay.Channels.Email.Bounce
  alias Relay.Channels.Email.Event

  @type action ::
          {:suppress, String.t(), integer() | nil}
          | :count_soft_bounce
          | {:reputation, :delivered | :bounce | :complaint}
          | {:sender_config, String.t() | nil}
          | {:unknown_code, String.t()}
          | {:evidence, String.t()}

  # CH-39
  # CH-40
  # CH-41
  # CH-8
  @doc "The actions of a classified event; an event without a classification has none."
  @spec plan(Event.t(), Bounce.t() | nil) :: [action()]
  def plan(%Event{}, nil), do: []
  def plan(%Event{}, %{kind: kind}) when kind in [:delayed, :not_spam], do: []

  def plan(%Event{} = event, %{kind: kind} = result) do
    case kind do
      :hard ->
        [{:suppress, "hard_bounce", nil}, {:reputation, :bounce}, {:evidence, "bounced"}]

      :soft ->
        [:count_soft_bounce, {:evidence, "rejected"}]

      :complaint ->
        [{:suppress, "complaint", nil}, {:reputation, :complaint}, evidence("complained")]

      :sender_config ->
        [{:sender_config, result.rule}, {:evidence, "rejected"}]

      :policy ->
        [{:reputation, :bounce}, {:evidence, "rejected"}]

      :content ->
        [{:evidence, "rejected"}]

      :unknown ->
        [{:unknown_code, "event:" <> event.code}, {:evidence, "rejected"}]

      :delivered ->
        [{:reputation, :delivered}, {:evidence, "delivered"}]
    end
  end

  defp evidence(code), do: {:evidence, code}

  # CH-40
  @doc "Decides a soft bounce of an address with the times (milliseconds) of its earlier soft bounces and the `soft_bounce` parameters of the `email_reputation` data set: `:count` below the window's count, otherwise the timed suppression's expiry, or `:no_duration` when the parameters name none."
  @spec soft_bounce([integer()], integer(), map()) ::
          :count | {:suppress, integer()} | :no_duration
  def soft_bounce(history, now_ms, params), do: Bounce.soft_bounce(history, now_ms, params)
end
