defmodule Relay.Api.Campaigns.Engine do
  @moduledoc """
  One step of a triggered campaign, run by its minute timer (`Relay.Api.Campaigns.TickJob`):

    * At the deadline its open stages are cancelled with `campaign.deadline_expired`, its waiting send jobs too, and it closes: the members left are counted `expired` and `campaign.expired` is published (WF-34).
    * A campaign kill switch in force pauses a running campaign under its rule; once no switch holds it, a campaign paused by a kill switch runs again (TN-40). A campaign paused by its alarm, a changed workflow or an exhausted quota waits for a tenant administrator (OP-47).
    * The current stage's fan-out follows the campaign's state: it is paused with the campaign and resumed with it.
    * A running campaign whose channel passes its alarm threshold (the warning thresholds of the `email_reputation` data set, on its minimum volume) pauses with `campaign.ramp_alarm` (WF-62).
    * The first stage opens at the first step; once a stage's members are all done the next stage opens PT15M later, and after the last stage the campaign closes `completed`, or `partial` when members were rejected (WF-62, T-23).
    * A campaign running longer than 1.5 times its estimate reports `[:relay, :campaign, :overrun]` once (OP-37).
  """

  alias Relay.Api.Campaigns
  alias Relay.Api.Campaigns.Plan
  alias Relay.Api.Campaigns.Store
  alias Relay.Tenancy.KillSwitch

  require Logger

  @classes Map.new(
             ~w(transactional operational social marketing system action_required)a,
             &{Atom.to_string(&1), &1}
           )
  @rates_window 20_000
  @deadline_rule "campaign.deadline_expired"

  # WF-62
  # WF-34
  # TN-40
  # OP-37
  @doc "Runs one step of a campaign; `:stop` once it is closed. `opts`: `:now` (the wall time, defaults to the clock's)."
  @spec tick(Relay.Scope.t(), Relay.Id.t(), keyword()) :: :continue | :stop
  def tick(scope, id, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &Relay.Clock.utc_now/0)

    case Campaigns.read(scope, id) do
      {:ok, %{"state" => state} = c} when state in ["running", "paused"] -> step(scope, c, now)
      {:ok, %{"state" => "cancelled"} = c} -> stop_stages(scope, c, "campaign.cancelled")
      {:ok, _other} -> :stop
      {:error, %Relay.Error{code: :campaign_not_found}} -> :stop
      {:error, _unavailable} -> :continue
    end
  end

  defp step(scope, c, now) do
    if DateTime.compare(Relay.Clock.business_now(scope), c["deadline"]) == :lt do
      c |> kill_switch(scope) |> follow(scope, now)
    else
      expire(scope, c)
    end
  end

  # WF-34
  defp expire(scope, c) do
    _ = stop_stages(scope, c, @deadline_rule)

    close = fn _status ->
      _ = Relay.Platform.cancel_waiting_jobs("campaign_batch", c["id"], @deadline_rule)
      Store.close(c["id"], @deadline_rule)
    end

    case Store.in_scope(scope, close) do
      {:ok, _closed} -> :stop
      {:error, _reason} -> :continue
    end
  end

  # TN-40
  defp kill_switch(c, scope) do
    message = %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      channel: "",
      message_class: c["message_class"],
      notification_id: c["id"],
      campaign_id: c["id"]
    }

    decision = KillSwitch.evaluate(KillSwitch.current_snapshot(), message, Relay.Clock.utc_now())

    case {c["state"], decision, c["pause_rule_id"]} do
      {"running", {:pause, _kill_switch_id, rule_id}, _rule} -> pause(scope, c, rule_id)
      {"paused", :allow, "killswitch." <> _rest} -> released(scope, c)
      _unchanged -> c
    end
  end

  @doc "Pauses a running campaign under a rule and its current stage's fan-out with it; returns the campaign as it is now."
  @spec pause(Relay.Scope.t(), map(), String.t()) :: map()
  def pause(scope, c, rule_id) do
    _ = Store.in_scope(scope, fn _status -> Store.pause(c["id"], rule_id) end)
    _ = with_fanout(scope, c, &Relay.Platform.pause_fanout(scope, &1, rule_id))
    reread(scope, c)
  end

  defp released(scope, c) do
    {:ok, actor} = Relay.Actor.new(:system, "system:campaign", "system:campaign")
    digest = Campaigns.digest(scope, "campaign.resumed", c["id"])
    resume = fn _status -> Store.resume(c["id"], "kill switch released", digest, actor) end
    _ = Store.in_scope(scope, resume)
    reread(scope, c)
  end

  defp reread(scope, c) do
    case Campaigns.read(scope, c["id"]) do
      {:ok, fresh} -> fresh
      {:error, _error} -> c
    end
  end

  defp follow(%{"state" => "paused"} = c, scope, _now) do
    _ = with_fanout(scope, c, &Relay.Platform.pause_fanout(scope, &1, c["pause_rule_id"]))
    :continue
  end

  defp follow(%{"state" => "running"} = c, scope, now) do
    _ = with_fanout(scope, c, &Relay.Platform.resume_fanout(scope, &1))
    :ok = overrun(scope, c, now)

    if alarm?(scope, c) do
      _ = pause(scope, c, "campaign.ramp_alarm")
      :continue
    else
      advance(scope, c, now)
    end
  end

  defp follow(_closed, _scope, _now), do: :continue

  defp with_fanout(scope, c, fun) do
    case current_stage(scope, c) do
      %{"fanout_id" => <<_::128>> = fanout_id} -> fun.(fanout_id)
      _none -> :none
    end
  end

  defp current_stage(scope, c) do
    case Store.in_scope(scope, fn _status -> Store.stages(c["id"]) end) do
      {:ok, stages} -> Enum.find(stages, &(&1["stage_no"] == c["stage_no"]))
      {:error, _reason} -> nil
    end
  end

  # WF-62
  # CH-37
  defp alarm?(scope, c) do
    with {:ok, thresholds} <- thresholds(),
         {:ok, rates} <- Store.in_scope(scope, fn _status -> rates(c) end) do
      Plan.alarm?(rates, thresholds)
    else
      _unreadable -> false
    end
  end

  defp rates(c), do: Store.rates(c["id"], @rates_window)

  defp thresholds do
    case Relay.Datasets.decide(Relay.Datasets.installation_scope(), "email_reputation", & &1) do
      {:ok, {%{"reputation" => p}, _ref}} ->
        {:ok,
         %{
           bounce_bp: p["warn_bounce_bp"],
           complaint_bp: p["warn_complaint_bp"],
           min_volume: p["min_volume"] || 0
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  # WF-62
  # T-23
  defp advance(scope, c, now) do
    stages =
      case Store.in_scope(scope, fn _status -> Store.stages(c["id"]) end) do
        {:ok, stages} -> stages
        {:error, _reason} -> []
      end

    current = Enum.find(stages, &(&1["stage_no"] == c["stage_no"]))
    next = Enum.find(stages, &(&1["stage_no"] == c["stage_no"] + 1))

    cond do
      current != nil and current["done_count"] < current["member_count"] -> :continue
      next == nil -> complete(scope, c)
      c["next_stage_at"] == nil -> wait(scope, c, now)
      DateTime.compare(now, c["next_stage_at"]) == :lt -> :continue
      true -> open(scope, c, next)
    end
  end

  defp complete(scope, c) do
    case Store.in_scope(scope, fn _status -> Store.close(c["id"], "campaign.completed") end) do
      {:ok, {:closed, _state}} -> :stop
      {:ok, {:already_closed, _state}} -> :stop
      _not_done -> :continue
    end
  end

  defp wait(scope, c, now) do
    until = DateTime.add(now, Plan.stage_wait_ms(), :millisecond)
    _ = Store.in_scope(scope, fn _status -> Store.stage_wait(c["id"], until) end)
    :continue
  end

  # T-23
  # T-91
  defp open(scope, c, stage) do
    size = Relay.Platform.fanout_slice_size()

    with {:ok, [_ | _] = bounds} <- Store.in_scope(scope, fn _ -> bounds(stage, size) end),
         {:ok, fanout_id} <- create_fanout(scope, c, stage, bounds),
         {:ok, _opened} <- Store.in_scope(scope, fn _ -> opened(c, stage, fanout_id) end) do
      :continue
    else
      other ->
        Logger.warning("a campaign stage could not open", result: inspect(other))
        :continue
    end
  end

  defp bounds(stage, size), do: Store.stage_bounds(stage["id"], size)

  defp opened(c, stage, fanout_id), do: Store.stage_open(c["id"], stage["stage_no"], fanout_id)

  defp create_fanout(scope, c, stage, bounds) do
    attrs = %{
      id: Relay.Id.generate(),
      source_kind: "campaign",
      source_id: stage["id"],
      lane: lane(c),
      bounds: bounds,
      recipient_count: c["audience_count"]
    }

    case Relay.Platform.create_fanout(scope, attrs) do
      {:ok, {result, fanout_id, _total}} when result in [:created, :exists] -> {:ok, fanout_id}
      other -> {:error, other}
    end
  end

  defp lane(c), do: Relay.Platform.lane(Map.fetch!(@classes, c["message_class"]))

  # OP-37
  defp overrun(_scope, %{"overrun_reported" => true}, _now), do: :ok

  defp overrun(scope, c, now) do
    if Plan.overrun?(c["triggered_at"], c["estimated_duration_s"], now),
      do: report_overrun(scope, c),
      else: :ok
  end

  defp report_overrun(scope, c) do
    case Store.in_scope(scope, fn _status -> Store.overrun(c["id"]) end) do
      {:ok, :reported} ->
        :telemetry.execute([:relay, :campaign, :overrun], %{count: 1}, %{lane: lane(c)})

      _already_or_unreadable ->
        :ok
    end
  end

  defp stop_stages(scope, c, rule_id) do
    {:ok, actor} = Relay.Actor.new(:system, "system:campaign", "system:campaign")
    digest = Campaigns.digest(scope, rule_id, c["id"])

    stages =
      case Store.in_scope(scope, fn _status -> Store.stages(c["id"]) end) do
        {:ok, stages} -> stages
        {:error, _reason} -> []
      end

    for %{"fanout_id" => <<_::128>> = fanout_id} <- stages,
        do: Relay.Platform.cancel_fanout(scope, fanout_id, rule_id, digest, actor)

    :stop
  end
end
