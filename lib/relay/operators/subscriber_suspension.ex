defmodule Relay.Operators.SubscriberSuspension do
  @moduledoc """
  Suspension of a subscriber (TN-73). A tenant operator or administrator suspends a subscriber through the operator API, and Access does through its `user.suspended` event for the subscriber whose `external_id` is the user's pairwise `sub`; lifting needs a tenant administrator with step-up, or Access's `user.reactivated` (TN-22). Each change is audited as `subscriber.suspended` or `subscriber.resumed`.

  While a subscriber is suspended a send to it is accepted and its deliveries are recorded as skipped with the rule `subscriber.suspended` (MD-12), its pending deliveries are `PAUSED` (`Relay.Operators.SuspensionWork`, TN-40), the subscriber token exchange and every subscriber endpoint answer `403 auth_subscriber_suspended`, and the signal `subscribers.suspended` of the tenant environment (`Relay.Platform.signal_topic/3`, carrying the subscriber's version) tells the realtime layer to close the subscriber's open connections (API-45). Lifting resumes the paused deliveries through the policy lattice.
  """

  require Logger

  alias Relay.Actor
  alias Relay.Operators.Store
  alias Relay.Operators.SuspensionWork
  alias Relay.Scope

  @page 100

  @type view :: %{
          subscriber_id: Relay.Id.t(),
          suspended: boolean(),
          suspended_at: DateTime.t() | nil,
          changed: boolean()
        }

  # TN-73
  # TN-40
  # API-45
  @doc "Suspends a subscriber of `scope` at once and pauses its pending deliveries; a subscriber that is already suspended stays so."
  @spec suspend(Scope.t(), Relay.Id.t(), String.t() | nil, Actor.t()) ::
          {:ok, view()} | {:error, Relay.Error.t()}
  def suspend(%Scope{} = scope, recipient_id, reason, %Actor{} = actor) do
    digest = digest(scope, "subscriber.suspended", actor, recipient_id, reason)

    change = &Store.subscriber_suspend(&1, reason, digest, actor)

    with {:ok, {result, version, row}} <- write(scope, recipient_id, change) do
      paused(scope, recipient_id)
      signal(scope, version)
      {:ok, view(recipient_id, row, result == :suspended)}
    end
  end

  # TN-73
  # TN-22
  # TN-40
  @doc "Lifts the suspension of a subscriber of `scope` and resumes its paused deliveries through the policy lattice; a subscriber that is not suspended is left as it is. `opts`: `:lattice`."
  @spec resume(Scope.t(), Relay.Id.t(), String.t() | nil, Actor.t(), keyword()) ::
          {:ok, view()} | {:error, Relay.Error.t()}
  def resume(%Scope{} = scope, recipient_id, reason, %Actor{} = actor, opts \\ []) do
    digest = digest(scope, "subscriber.resumed", actor, recipient_id, reason)

    change = &Store.subscriber_resume(&1, reason, digest, actor)

    with {:ok, {result, _version, row}} <- write(scope, recipient_id, change) do
      resumed(scope, recipient_id, actor, opts)
      {:ok, view(recipient_id, row, result == :resumed)}
    end
  end

  defp write(scope, recipient_id, change) do
    work = fn _status ->
      case change.(recipient_id) do
        {:not_found, _version} -> {:error, not_found()}
        {result, version} -> {:ok, {result, version, Store.subscriber_suspension(recipient_id)}}
      end
    end

    case Store.in_scope(scope, work) do
      {:ok, result} -> result
      {:error, %Relay.Error{code: :not_found}} -> {:error, not_found()}
      {:error, %Relay.Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp paused(scope, recipient_id) do
    with {:error, reason} <- SuspensionWork.pause_subscriber(scope, recipient_id),
         do: warn("pause", reason)
  end

  defp resumed(scope, recipient_id, actor, opts) do
    opts = Keyword.put(opts, :actor, actor)

    case SuspensionWork.resume_subscriber(scope, recipient_id, opts) do
      {:ok, _totals} -> :ok
      {:error, reason} -> warn("resume", reason)
    end
  end

  # API-45
  # TN-17
  @doc "The signal topic of the subscriber suspensions of `scope`; the realtime layer closes the open connections of a suspended subscriber when it fires."
  @spec topic(Scope.t()) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  def topic(%Scope{} = scope) do
    Relay.Platform.signal_topic(
      Scope.tenant_text(scope),
      Relay.Environment.dump(scope.environment),
      ["subscribers", "suspended"]
    )
  end

  defp signal(scope, version) when is_integer(version) do
    with {:ok, topic} <- topic(scope),
         {:error, error} <- Relay.Platform.publish_signal(topic, version),
         do: Logger.debug("subscriber suspension signal not sent", code: error.code)
  end

  defp signal(_scope, _version), do: :ok

  defp view(recipient_id, row, changed) do
    %{
      subscriber_id: recipient_id,
      suspended: row["suspended_at"] != nil,
      suspended_at: row["suspended_at"],
      changed: changed
    }
  end

  # TN-73
  # TN-20
  @doc "Reflects an Access user lifecycle event on the subscribers whose `external_id` is the user's pairwise `sub`, in every tenant environment that is not closed: `:suspended` suspends them and `:reactivated` lifts their suspension. Called by `Relay.Operators.AccessSubscriberHandler` with the event's SET `jti`."
  @spec access_changed(:suspended | :reactivated, String.t(), String.t()) ::
          :ok | {:error, term()}
  def access_changed(kind, subject, event_ref)
      when kind in [:suspended, :reactivated] and is_binary(subject) do
    {:ok, actor} = Actor.new(:access, "access", "access", event_ref)
    reason = "access:user." <> Atom.to_string(kind)
    each_tenant(nil, &access_tenant(&1, kind, subject, reason, actor))
  end

  defp each_tenant(after_id, fun) do
    case Store.subscriber_tenants(after_id, @page) do
      [] ->
        :ok

      tenants ->
        case Enum.reduce_while(tenants, :ok, &tenant_step(&1, &2, fun)) do
          :ok when length(tenants) == @page -> each_tenant(List.last(tenants), fun)
          result -> result
        end
    end
  end

  defp tenant_step(tenant_id, :ok, fun) do
    case fun.(tenant_id) do
      :ok -> {:cont, :ok}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp access_tenant(tenant_id, kind, subject, reason, actor) do
    Enum.reduce_while(Relay.Environment.all(), :ok, fn environment, :ok ->
      scope = Scope.new!(tenant_id, environment)

      case access_scope(scope, kind, subject, reason, actor) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp access_scope(scope, kind, subject, reason, actor) do
    with {:ok, ids} <- subscribers(scope, subject),
         do: Enum.reduce_while(ids, :ok, &access_step(scope, kind, &1, reason, actor, &2))
  end

  defp access_step(scope, kind, id, reason, actor, :ok) do
    case access_apply(scope, kind, id, reason, actor) do
      {:ok, _view} -> {:cont, :ok}
      {:error, %Relay.Error{code: :subscriber_not_found}} -> {:cont, :ok}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp access_apply(scope, :suspended, id, reason, actor), do: suspend(scope, id, reason, actor)
  defp access_apply(scope, :reactivated, id, reason, actor), do: resume(scope, id, reason, actor)

  defp subscribers(scope, subject) do
    case Relay.Subscribers.indexes(scope, [subject]) do
      {:ok, bidxs} ->
        Store.in_scope(scope, fn _status -> Relay.Subscribers.resolve_indexes(bidxs) end)

      {:error, %Relay.Error{code: :blind_index_key_unavailable}} ->
        {:ok, []}

      {:error, error} ->
        {:error, error}
    end
  end

  defp digest(scope, action, actor, recipient_id, reason) do
    target = Relay.Id.to_string(recipient_id)
    Relay.Operators.record_digest(scope, action, actor, "recipient", target, reason)
  end

  defp warn(step, reason) do
    Logger.warning("the subscriber suspension's pending work did not complete",
      step: step,
      reason: inspect(reason)
    )
  end

  defp not_found, do: Relay.Error.new(:subscriber_not_found, "no such subscriber")
  defp unavailable, do: Relay.Error.new(:service_unavailable, "the subscriber is unavailable")
end
