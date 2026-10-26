defmodule Relay.Delivery.RetryPolicy do
  @moduledoc """
  What happens after a failed attempt, as a pure function of the failure, the `channel_parameters` snapshot, the database clock of the finishing transaction and the retry budget decision (T-26, CH-9, CH-12).

  - A permanent class is never retried (INV-14): `permanent_target`, `permanent_content` and `sender_config` go to the dead letters as `permanent`; `policy` fails the delivery with a rule and no dead letter.
  - An attempt with an uncertain outcome is not retried blindly (T-28).
  - Otherwise the backoff row decides. Without a row no retry is planned and the delivery goes to the dead letters as `exhausted` (CH-70). After `max_attempts` attempts the delivery is `exhausted`.
  - The wait is full-jitter exponential backoff from the deterministic jitter (`Relay.Jitter.backoff/6`). A provider `Retry-After` is always honoured and never shortened by local backoff: the wait is the larger of the backoff and `Retry-After` plus 0–20 % (CH-9).
  - A retry whose deterministic start is at or after the message's `expires_at` is not planned; the delivery expires (CH-12).
  - A retry the budget denies goes to the dead letters as `budget_denied` (T-27).
  - A planned retry runs at a lower priority: 2 for the second and third attempt, 8 from the fourth (T-36).
  """

  @type input :: %{
          required(:tenant_id) => Relay.Id.t(),
          required(:environment) => Relay.Environment.t(),
          required(:delivery_id) => Relay.Id.t(),
          required(:attempt_no) => pos_integer(),
          required(:failure_class) => String.t() | atom(),
          required(:channel) => String.t() | atom(),
          required(:now) => DateTime.t(),
          required(:parameters) => Relay.ChannelParameters.t(),
          optional(:state) => :failed | :unknown,
          optional(:condition) => String.t() | atom() | nil,
          optional(:provider) => String.t() | nil,
          optional(:message_class) => String.t() | atom() | nil,
          optional(:retry_after_ms) => non_neg_integer() | nil,
          optional(:expires_at) => DateTime.t() | nil,
          optional(:budget) => :allow | :deny,
          optional(:rule_id) => String.t() | nil
        }

  @type dlq_class :: :permanent | :exhausted | :budget_denied
  @type plan ::
          {:retry, DateTime.t(), 0..9, pos_integer()}
          | {:dead_letter, dlq_class(), String.t()}
          | {:expire, String.t()}
          | {:fail, String.t()}
          | {:no_retry, String.t()}

  # T-26
  # T-28
  # CH-9
  # CH-12
  # CH-70
  # INV-14
  # T-27
  @doc "Plans what follows the `attempt_no`-th failed attempt of a delivery."
  @spec next(input()) :: plan()
  def next(%{} = input) do
    class = text(input.failure_class)

    cond do
      Map.get(input, :state, :failed) == :unknown ->
        {:no_retry, "retry.uncertain"}

      class == "policy" ->
        {:fail, Map.get(input, :rule_id) || "retry.policy"}

      class in Relay.ChannelParameters.permanent_classes() ->
        {:dead_letter, :permanent, "retry.permanent"}

      true ->
        retryable(input, class)
    end
  end

  defp retryable(input, class) do
    case Relay.ChannelParameters.backoff(
           input.parameters,
           input.channel,
           Map.get(input, :provider),
           class,
           Map.get(input, :condition),
           Map.get(input, :message_class)
         ) do
      {:error, :missing} ->
        {:dead_letter, :exhausted, "channel_parameters.missing"}

      {:ok, %{"max_attempts" => max}, _version} when input.attempt_no >= max ->
        {:dead_letter, :exhausted, "retry.max_attempts"}

      {:ok, row, _version} ->
        plan(input, row)
    end
  end

  defp plan(input, row) do
    at = DateTime.add(input.now, wait_ms(input, row), :millisecond)
    expires_at = Map.get(input, :expires_at)

    cond do
      expires_at != nil and DateTime.compare(at, expires_at) != :lt ->
        {:expire, "retry.expires_at"}

      Map.get(input, :budget, :allow) == :deny ->
        {:dead_letter, :budget_denied, "retry.budget_denied"}

      true ->
        {:retry, at, priority(input.attempt_no + 1), input.attempt_no + 1}
    end
  end

  # T-26
  # CH-9
  @doc "The wait in milliseconds before the next attempt under a backoff row."
  @spec wait_ms(input(), map()) :: non_neg_integer()
  def wait_ms(input, row) do
    n = input.attempt_no

    local =
      if row["mode"] == "exponential",
        do:
          Relay.Jitter.backoff(
            input.tenant_id,
            input.environment,
            input.delivery_id,
            n,
            row["base_ms"],
            row["cap_ms"]
          ),
        else: 0

    retry_after =
      Map.get(input, :retry_after_ms) ||
        if(row["mode"] == "retry_after", do: row["default_retry_after_ms"])

    if retry_after,
      do:
        max(
          local,
          Relay.Jitter.retry_after(
            input.tenant_id,
            input.environment,
            input.delivery_id,
            n,
            retry_after
          )
        ),
      else: local
  end

  # T-36
  @doc "The job priority of an attempt: 2 for the second and third attempt, 8 from the fourth."
  @spec priority(pos_integer()) :: 2 | 8
  def priority(attempt_no) when attempt_no in [2, 3], do: 2
  def priority(attempt_no) when is_integer(attempt_no) and attempt_no >= 4, do: 8

  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value) when is_binary(value), do: value
end
