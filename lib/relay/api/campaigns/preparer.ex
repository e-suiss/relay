defmodule Relay.Api.Campaigns.Preparer do
  @moduledoc """
  The preparation of a campaign (WF-44, X-14): its frozen audience is read in identifier order, a page of 500 members at a time with the checkpoint in the campaign record, and every member's channel steps are evaluated in a dry run: a deleted subscriber is `campaign.recipient_unavailable`, a suspended one `subscriber.suspended`, a template that cannot send its template rule, and otherwise the policy lattice decides (`Relay.Policy.Live.decide/1`) with no frequency counter read. Nothing is opened, pinned or counted. A send or a deferral counts for its channel, every other outcome as a drop under its `rule_id`; a member with at least one sending or deferred channel is reachable. A workflow whose published version is no longer the frozen one drops every member left with `campaign.workflow_changed`.

  One job runs at most ten pages and queues the next job in the transaction of its last page; after the last page the cost estimate is computed from the price table of the channel's first active provider account and the campaign becomes `prepared`.
  """

  alias Relay.Api.Campaigns
  alias Relay.Api.Campaigns.Plan
  alias Relay.Api.Campaigns.PrepareJob
  alias Relay.Api.Campaigns.Store
  alias Relay.Channels.Live, as: Channels
  alias Relay.Policy.Live
  alias Relay.Templates.Live, as: Templates

  @page 500
  @pages_per_job 10
  @no_readings %{global: nil, policy: nil}
  @throughput_per_second 100
  @channels Map.new(
              ~w(push web_push email sms voice whatsapp slack teams telegram discord in_app
                 webhook)a,
              &{Atom.to_string(&1), &1}
            )
  @classes Map.new(
             ~w(transactional operational social marketing system action_required)a,
             &{Atom.to_string(&1), &1}
           )

  # WF-44
  # X-14
  @doc "Runs up to ten pages of a preparing campaign's dry evaluation; ends the preparation after the last page."
  @spec run(Relay.Scope.t(), Relay.Id.t()) :: :ok | {:error, term()}
  def run(scope, id) do
    with {:ok, %{"state" => "preparing"} = c} <- Campaigns.read(scope, id),
         {:ok, ctx} <- context(scope, c) do
      pages(scope, c, ctx, 1)
    else
      {:ok, _not_preparing} -> :ok
      {:error, %Relay.Error{code: :campaign_not_found}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp context(scope, c) do
    class = Map.fetch!(@classes, c["message_class"])

    case Relay.Workflow.resolve_published(scope, c["workflow_key"]) do
      {:ok, {:ok, workflow}} -> frozen(scope, c, workflow, class)
      {:ok, _not_published} -> {:ok, %{changed: true}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp frozen(scope, c, workflow, class) do
    if workflow["version_no"] == c["workflow_version_no"],
      do: category_context(scope, c, workflow, class),
      else: {:ok, %{changed: true}}
  end

  defp category_context(scope, c, workflow, class) do
    key = workflow["definition"]["category"] || workflow["message_class"]

    case Live.category(scope, key, class, nil) do
      {:ok, category} ->
        {:ok,
         %{
           changed: false,
           scope: scope,
           steps: Relay.Workflow.steps(workflow["definition"]),
           category: category,
           class: class,
           workflow_key: workflow["key"],
           notification: notification(c, class)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp notification(c, class) do
    {priority, _clamped?} = Live.clamp_priority(class, nil)

    Live.notification(%{
      message_class: c["message_class"],
      security_subtype: nil,
      priority: Atom.to_string(priority),
      expires_at: c["deadline"],
      sender_type: nil
    })
  end

  defp pages(scope, c, ctx, n) do
    last? = n >= @pages_per_job

    case Store.in_scope(scope, fn _status -> page(scope, c["id"], ctx, last?) end) do
      {:ok, :more} when last? -> :ok
      {:ok, :more} -> pages(scope, c, ctx, n + 1)
      {:ok, :done} -> finish(scope, c["id"])
      {:ok, :not_preparing} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp page(scope, id, ctx, last?) do
    fresh = Store.get(id)
    members = Store.members_after(id, fresh["prepare_after"], @page)
    templates = if ctx.changed, do: nil, else: Templates.templates(template_keys(ctx), nil)

    case members do
      [] ->
        :done

      members ->
        {reachable, counts} = evaluate(members, ctx, templates)
        last = List.last(members)["id"]

        case Store.prepare_progress(id, last, length(members), reachable, counts) do
          :not_preparing -> :not_preparing
          _recorded_or_stale -> next(scope, id, length(members) < @page, last?)
        end
    end
  end

  defp next(_scope, _id, true, _last?), do: :done
  defp next(_scope, _id, false, false), do: :more

  defp next(scope, id, false, true) do
    case Oban.insert(PrepareJob.new(Campaigns.job_args(scope, id))) do
      {:ok, _job} -> :more
      {:error, reason} -> Store.rollback({:job_not_queued, reason})
    end
  end

  defp template_keys(ctx), do: Enum.map(ctx.steps, & &1.template)

  defp evaluate(members, ctx, templates) do
    outcomes = Enum.map(members, &member(&1, ctx, templates))
    reachable = Enum.count(outcomes, fn list -> Enum.any?(list, &reached?/1) end)

    counts =
      outcomes
      |> List.flatten()
      |> Enum.frequencies()
      |> Enum.map(fn {{kind, key}, count} -> {Atom.to_string(kind), key, count} end)

    {reachable, counts}
  end

  defp reached?({kind, _key}), do: kind in [:send, :defer]

  defp member(_m, %{changed: true}, _templates), do: [{:drop, "campaign.workflow_changed"}]

  defp member(m, ctx, templates) do
    case Relay.Subscribers.row(m["recipient_id"]) do
      nil -> [{:drop, "campaign.recipient_unavailable"}]
      %{"state" => "deleted"} -> [{:drop, "campaign.recipient_unavailable"}]
      %{"suspended_at" => %DateTime{}} -> [{:drop, "subscriber.suspended"}]
      row -> Enum.map(ctx.steps, &step(&1, device_locale(row), ctx, templates))
    end
  end

  # TP-25
  defp device_locale(row) do
    locale = Enum.find_value(Relay.Devices.current(row["id"]), & &1["locale"])
    Map.put(row, "device_locale", locale)
  end

  # PC-58 (8)
  # TP-51
  defp step(step, row, ctx, templates) do
    case Templates.choose(templates, step, row) do
      {:skip, _reason, rule, _detail} -> {:drop, rule}
      {:ok, _plan} -> lattice(step, row, ctx)
    end
  end

  defp lattice(step, row, ctx) do
    channel = Map.fetch!(@channels, step.channel)

    input = %{
      scope: ctx.scope,
      now: Relay.Clock.business_now(ctx.scope),
      delivery_id: Relay.Id.generate(),
      recipient_id: row["id"],
      subtenant_id: nil,
      channel: channel,
      category: ctx.category,
      workflow_key: ctx.workflow_key,
      notification: ctx.notification,
      frequency: @no_readings
    }

    case Live.decide(input) do
      {:send, _info} -> {:send, step.channel}
      {:defer, _reason, _rule, _until, _detail} -> {:defer, step.channel}
      {:skip, _reason, rule, _detail} -> {:drop, rule}
      {:expire, rule, _detail} -> {:drop, rule}
      {:error, _input_unavailable} -> {:drop, "campaign.preview_unavailable"}
    end
  end

  # X-14
  # CH-18
  # OP-37
  defp finish(scope, id) do
    with {:ok, c} <- Campaigns.read(scope, id) do
      estimate = estimate(scope, read_counts(scope, id))
      duration = Plan.estimated_duration_s(c["audience_count"], @throughput_per_second)
      prepared(Store.in_scope(scope, fn _status -> Store.prepared(id, estimate, duration) end))
    end
  end

  defp prepared({:ok, _result}), do: :ok
  defp prepared({:error, reason}), do: {:error, reason}

  defp read_counts(scope, id) do
    case Store.in_scope(scope, fn _status -> Store.preview_counts(id) end) do
      {:ok, rows} -> rows
      {:error, _reason} -> []
    end
  end

  defp estimate(scope, counts) do
    totals = Enum.reduce(counts, %{}, &add_count/2)

    pricer =
      case Channels.usage_pricing() do
        {:ok, pricer} -> pricer
        {:error, _reason} -> &unpriced/5
      end

    rows = for {channel, count} <- Enum.sort(totals), do: price(scope, pricer, channel, count)
    %{"channels" => rows}
  end

  defp unpriced(_provider, _channel, _country, _category, _volume), do: :unpriced

  defp add_count(%{"kind" => kind} = row, acc) when kind in ["send", "defer"],
    do: Map.update(acc, row["key"], row["count"], &(&1 + row["count"]))

  defp add_count(_drop, acc), do: acc

  defp price(scope, pricer, channel, count) do
    base = %{"channel" => channel, "count" => count}

    with {:ok, [provider | _others]} <- Relay.Channels.active_providers(scope, channel),
         {:ok, unit} <- pricer.(provider, channel, nil, nil, 0) do
      Map.merge(base, %{
        "provider" => provider,
        "currency" => unit.currency,
        "unit" => unit.unit,
        "unit_price_micros" => unit.unit_price_micros,
        "cost_micros" => unit.unit_price_micros * count
      })
    else
      _unpriced -> Map.merge(base, %{"provider" => nil, "currency" => nil, "cost_micros" => nil})
    end
  end
end
