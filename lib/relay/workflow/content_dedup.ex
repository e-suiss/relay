defmodule Relay.Workflow.ContentDedup do
  @moduledoc """
  Content deduplication (WF-35, WF-36): after a delivery is rendered, the same recipient, the same channel and the same rendered content digest inside the window is not sent again; the repeat is recorded as skipped with `reason = duplicate_content` and `rule_id = content_dedup.same_content`, naming the delivery it repeats. It is off by default; the `operational` class has it on with a PT5M window (POLICY DEFAULT) and a workflow turns it on or sets its window with `content_dedup: {window}` (PT1M … PT24H). The `security` class, which carries Access semantic events and OTP, is never deduplicated by content; its idempotency and `dedup_key` still apply.

  It is a protection of its own, apart from the `Idempotency-Key` (a repeated request), the `dedup_key` (a repeated event) and the delivery ledger's `(notification, recipient, channel)` uniqueness (WF-36). A repeat is matched against the earlier deliveries that were rendered within the window and not skipped, cancelled or expired, in render order, so of two identical deliveries the later one is the repeat.
  """

  alias Relay.Workflow.ContentDedup.Store
  alias Relay.Workflow.Span

  @operational_ms Relay.Limits.seconds!(["content_dedup", "operational_window"]) * 1_000
  @min_ms Relay.Limits.seconds!(["content_dedup", "min_window"]) * 1_000
  @max_ms Relay.Limits.seconds!(["content_dedup", "max_window"]) * 1_000
  @rule "content_dedup.same_content"

  # WF-35
  @doc "The rule a content repeat is recorded with."
  @spec rule_id() :: String.t()
  def rule_id, do: @rule

  # WF-35
  # WF-36
  # E-11
  @doc "The deduplication window of a delivery in milliseconds, or `nil` when content deduplication is off: never for `security`, the workflow's `content_dedup.window` when it is a valid window, else PT5M for `operational`."
  @spec window_ms(String.t() | nil, term()) :: pos_integer() | nil
  def window_ms("security", _content_dedup), do: nil

  def window_ms(class, %{"window" => text}) do
    case Span.ms(text) do
      {:ok, ms} when ms >= @min_ms and ms <= @max_ms -> ms
      _invalid -> window_ms(class, nil)
    end
  end

  def window_ms("operational", _content_dedup), do: @operational_ms
  def window_ms(_class, _content_dedup), do: nil

  # WF-35
  # WF-59
  @doc "Checks the `content_dedup` field of a definition; returns its field errors under `pointer`."
  @spec errors(term(), String.t()) :: [map()]
  def errors(nil, _pointer), do: []

  def errors(%{"window" => text} = field, pointer) when map_size(field) == 1 do
    case Span.ms(text) do
      {:ok, ms} when ms >= @min_ms and ms <= @max_ms -> []
      _invalid -> [error("#{pointer}/window", "the window is from PT1M to PT24H")]
    end
  end

  def errors(_field, pointer), do: [error(pointer, "content_dedup is {window}")]

  # WF-35
  # WF-36
  @doc "Checks a rendered delivery for a content repeat in its own transaction and records a repeat as skipped: `:send` or `:skipped`; `{:error, reason}` when the check cannot be read, so the job retries."
  @spec check(Relay.Scope.t(), Relay.Id.t()) :: :send | :skipped | {:error, term()}
  def check(%Relay.Scope{} = scope, delivery_id) do
    result =
      Store.in_scope(scope, fn _status ->
        case Store.inputs(delivery_id) do
          nil -> :send
          %{class: class, content_dedup: field} -> checked(delivery_id, window_ms(class, field))
        end
      end)

    case result do
      {:ok, outcome} -> outcome
      {:error, reason} -> {:error, reason}
    end
  end

  defp checked(_delivery_id, nil), do: :send

  defp checked(delivery_id, window_ms) do
    case Store.check(delivery_id, window_ms) do
      :duplicate -> :skipped
      _unique_or_closed -> :send
    end
  end

  defp error(pointer, detail), do: %{pointer: pointer, code: "invalid_value", detail: detail}
end
