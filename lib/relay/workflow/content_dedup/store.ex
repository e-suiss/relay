defmodule Relay.Workflow.ContentDedup.Store do
  @moduledoc """
  Data access of content deduplication: the message class and the workflow's `content_dedup` field of a delivery, and `relay_fn.content_dedup_check`. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Repo

  @inputs """
  SELECT n.message_class::text AS message_class, v.definition -> 'content_dedup' AS content_dedup
  FROM relay.deliveries d
  JOIN relay.notifications n ON n.tenant_id = d.tenant_id AND n.environment = d.environment
    AND n.id = d.notification_id
  LEFT JOIN relay.workflow_versions v ON v.tenant_id = n.tenant_id
    AND v.environment = n.environment AND v.id = n.workflow_version_id
  WHERE d.tenant_id = relay_private.ctx_tenant_id()
    AND d.environment = relay_private.ctx_environment() AND d.id = $1
  """

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # WF-35
  @doc "The message class and the workflow's `content_dedup` field of a delivery; `nil` when it is gone."
  @spec inputs(Relay.Id.t()) :: %{class: String.t(), content_dedup: term()} | nil
  def inputs(delivery_id) do
    case Repo.scoped_query!(@inputs, [delivery_id]) do
      %Postgrex.Result{rows: [[class, field]]} -> %{class: class, content_dedup: field}
      %Postgrex.Result{rows: []} -> nil
    end
  end

  # WF-35
  # WF-36
  @doc "Records a rendered delivery as skipped when it repeats an earlier one inside the window; see `relay_fn.content_dedup_check`."
  @spec check(Relay.Id.t(), pos_integer()) ::
          :unique | :duplicate | :not_rendered | :closed | :not_found
  def check(delivery_id, window_ms) do
    [row] = Repo.call!("relay_fn.content_dedup_check", [delivery_id, window_ms])
    Repo.code!(row["result"], [:unique, :duplicate, :not_rendered, :closed, :not_found])
  end
end
