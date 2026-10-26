defmodule Relay.Tenancy.DeadMan do
  @moduledoc """
  The dead-man switch (TN-43): abnormal volume pauses its scope on its own. Each attempt start of a tenant, campaign or workflow (never of a `security` message) adds one to that scope's per-minute ring counter (`dms:<scope_kind>:<scope_ref | tenant>`). The switch trips when the rate of the current window exceeds ten times the rate of the baseline window and the current window holds at least the floor; the values are those of T-91 (1): a five-minute window, the previous sixty minutes as baseline and a floor of 500 messages.

  A trip engages a `paused_until` record without end and without TTL (`no_ttl_approval_ref = 'TN-43'`, S-53) and with no message class, so it never stops `security`; it audits `killswitch.auto_paused` and notifies the tenant and the operations channel through the outbox. Opening it again is a human decision: a release with approval.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  @factor 10
  @current_minutes 5
  @baseline_minutes 60
  @floor 500

  @type params :: %{
          factor: pos_integer(),
          current_minutes: pos_integer(),
          baseline_minutes: pos_integer(),
          floor: non_neg_integer()
        }

  # TN-43
  # T-91 (1)
  @doc "The trip parameters: factor 10, current window 5 minutes, baseline 60 minutes, floor 500."
  @spec params() :: params()
  def params,
    do: %{
      factor: @factor,
      current_minutes: @current_minutes,
      baseline_minutes: @baseline_minutes,
      floor: @floor
    }

  # TN-43
  # T-91 (1)
  @doc "Returns true when `current_sum / current_minutes > factor · baseline_sum / baseline_minutes` and `current_sum ≥ floor`."
  @spec trip?({non_neg_integer(), non_neg_integer()}, params()) :: boolean()
  def trip?({current_sum, baseline_sum}, params \\ params())
      when is_integer(current_sum) and current_sum >= 0 and is_integer(baseline_sum) and
             baseline_sum >= 0 do
    current_sum >= params.floor and
      current_sum * params.baseline_minutes >
        params.factor * baseline_sum * params.current_minutes
  end

  @doc "The counter key of a scope."
  @spec key(:tenant | :campaign | :workflow, String.t() | nil) :: String.t()
  def key(:tenant, nil), do: "dms:tenant:tenant"

  def key(kind, ref) when kind in [:campaign, :workflow] and is_binary(ref),
    do: "dms:#{kind}:#{ref}"

  @doc "The reason text of an automatic pause."
  @spec reason({non_neg_integer(), non_neg_integer()}, params()) :: String.t()
  def reason({current_sum, baseline_sum}, params \\ params()) do
    ratio =
      if baseline_sum == 0,
        do: "inf",
        else:
          :erlang.float_to_binary(
            current_sum * params.baseline_minutes / (baseline_sum * params.current_minutes),
            decimals: 1
          )

    "dead_man: #{ratio}× over 1h baseline"
  end
end
