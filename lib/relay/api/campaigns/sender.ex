defmodule Relay.Api.Campaigns.Sender do
  @moduledoc """
  The send step of one campaign sub-batch (WF-44, WF-34): the trigger only sends. A running campaign before its deadline and not held by a campaign kill switch sends its pending members of the sub-batch: each is one event of the frozen workflow version with the campaign data, the member's `dedup_key` and `expires_at` at the deadline, prepared outside any transaction (`Relay.Api.Events.prepare/3`) and accepted in a savepoint of one transaction together with the member's mark, so a retried job never sends a member twice. Accepting goes through the policy lattice, the quotas and the queues of every event: nothing raises the send rate above the provider limits to meet the deadline.

  A member whose subscriber is gone, or whose event is refused, is marked `rejected` with the error code. A changed published workflow version pauses the campaign with `campaign.workflow_changed` and an exhausted quota with `campaign.quota_exhausted`; a paused campaign's job waits a minute; a closed or cancelled one's ends.
  """

  alias Relay.Api.Campaigns
  alias Relay.Api.Campaigns.Engine
  alias Relay.Api.Campaigns.Store
  alias Relay.Api.Events
  alias Relay.Tenancy.KillSwitch

  @snooze_s 60
  @retry [:service_unavailable]
  @whole_request [:auth_tenant_suspended, :auth_environment_mismatch]

  # WF-44
  # WF-34
  # TN-40
  @doc "Sends the pending members from `from` to `to` of a campaign."
  @spec run(Relay.Scope.t(), Relay.Id.t(), Relay.Id.t(), Relay.Id.t()) ::
          :ok | {:snooze, pos_integer()} | {:error, term()}
  def run(scope, id, from, to) do
    read = fn _status -> {Store.get(id), Store.pending_members(id, from, to)} end

    case Store.in_scope(scope, read) do
      {:ok, {nil, _members}} -> :ok
      {:ok, {c, members}} -> gate(scope, c, members)
      {:error, reason} -> {:error, reason}
    end
  end

  defp gate(scope, %{"state" => "running"} = c, members) do
    cond do
      DateTime.compare(Relay.Clock.business_now(scope), c["deadline"]) != :lt -> :ok
      members == [] -> :ok
      true -> kill_switch(scope, c, members)
    end
  end

  defp gate(_scope, %{"state" => "paused"}, _members), do: {:snooze, @snooze_s}
  defp gate(_scope, _closed, _members), do: :ok

  # TN-40
  defp kill_switch(scope, c, members) do
    message = %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      channel: "",
      message_class: c["message_class"],
      notification_id: c["id"],
      campaign_id: c["id"]
    }

    case KillSwitch.evaluate(KillSwitch.current_snapshot(), message, Relay.Clock.utc_now()) do
      :allow ->
        send_members(scope, c, members)

      {:pause, _kill_switch_id, rule_id} ->
        _ = Engine.pause(scope, c, rule_id)
        {:snooze, @snooze_s}

      {:hold, _rule_id} ->
        {:snooze, 5}
    end
  end

  defp send_members(scope, c, members) do
    with {:ok, data} <- Campaigns.open_data(scope, c),
         {:ok, external} <- external_ids(scope, members) do
      ctx = context(scope, c)
      prepared = Enum.map(members, &{&1, prepare(ctx, c, data, external, &1)})

      scope
      |> Store.in_scope(fn _status -> accept_all(prepared, c, ctx) end)
      |> finished(scope, c)
    end
  end

  defp external_ids(scope, members) do
    case Relay.Subscribers.external_ids(scope, Enum.map(members, & &1["recipient_id"])) do
      {:ok, found} -> {:ok, found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp context(scope, c) do
    {:ok, actor} = Relay.Actor.new(:system, "system:campaign", c["api_client_ref"] || "campaign")

    %{
      scope: scope,
      actor: actor,
      api_client_id: c["api_client_ref"],
      subtenant_id: nil,
      traceparent: nil,
      agent: false
    }
  end

  defp prepare(ctx, c, data, external, member) do
    case Map.get(external, member["recipient_id"]) do
      nil -> {:error, :recipient_not_found}
      external_id -> prepare_event(ctx, c, data, external_id, member)
    end
  end

  defp prepare_event(ctx, c, data, external_id, member) do
    body = %{
      "workflow" => c["workflow_key"],
      "to" => [external_id],
      "data" => data,
      "expires_at" => DateTime.to_iso8601(c["deadline"])
    }

    Events.prepare(ctx, body, dedup_key: member["dedup_key"])
  end

  defp accept_all(prepared, c, ctx) do
    Enum.reduce_while(prepared, :ok, fn {member, result}, :ok ->
      case accept(member, result, c, ctx) do
        :ok -> {:cont, :ok}
        stop -> {:halt, stop}
      end
    end)
  end

  defp accept(member, {:ok, p}, c, ctx) do
    if p.workflow["version_no"] == c["workflow_version_no"],
      do: accept_event(member, p, c, ctx),
      else: {:pause, "campaign.workflow_changed"}
  end

  defp accept(member, {:error, :recipient_not_found}, c, _ctx),
    do: reject(member, c, "recipient_not_found")

  defp accept(member, {:error, %Relay.Error{} = error}, c, _ctx), do: refused(member, c, error)

  defp accept_event(member, p, c, ctx) do
    result =
      Relay.Ingest.savepoint(fn ->
        with {:ok, view} <- Events.accept(p, ctx),
             {:ok, notification_id} <- notification(view) do
          marked(Store.mark(c["id"], member["id"], :accepted, notification_id, nil))
        end
      end)

    case result do
      {:ok, _marked} -> :ok
      {:error, :not_running} -> :stopped
      {:error, %Relay.Error{} = error} -> refused(member, c, error)
    end
  end

  defp marked(:marked), do: {:ok, :marked}
  defp marked(:not_pending), do: {:ok, :not_pending}
  defp marked(_not_running_or_missing), do: {:error, :not_running}

  defp notification(%{"notifications" => [%{"notification_id" => external} | _rest]}) do
    case Relay.ExternalId.decode(external, ["ntf"]) do
      {:ok, id} -> {:ok, id}
      {:error, error} -> {:error, error}
    end
  end

  defp notification(_view),
    do: {:error, Relay.Error.new(:service_unavailable, "the event opened no notification")}

  defp refused(_member, _c, %Relay.Error{code: :quota_exhausted}),
    do: {:pause, "campaign.quota_exhausted"}

  defp refused(_member, _c, %Relay.Error{code: code}) when code in @retry, do: :retry
  defp refused(_member, _c, %Relay.Error{code: code}) when code in @whole_request, do: :stopped
  defp refused(member, c, %Relay.Error{code: code}), do: reject(member, c, Atom.to_string(code))

  defp reject(member, c, code) do
    case Store.mark(c["id"], member["id"], :rejected, nil, code) do
      :not_running -> :stopped
      _marked_or_done -> :ok
    end
  end

  defp finished({:ok, :ok}, _scope, _c), do: :ok
  defp finished({:ok, :stopped}, _scope, _c), do: {:snooze, @snooze_s}
  defp finished({:ok, :retry}, _scope, _c), do: {:error, :unavailable}

  defp finished({:ok, {:pause, rule_id}}, scope, c) do
    _ = Engine.pause(scope, c, rule_id)
    {:snooze, @snooze_s}
  end

  defp finished({:error, reason}, _scope, _c), do: {:error, reason}
end
