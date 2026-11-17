defmodule Relay.Api.Courier.Provision do
  @moduledoc """
  The protected workflow and template of an Access message type in the Access platform tenant (E-108, E-35, TP-52), written when a message of the type first arrives and the workflow is missing. In one transaction of the scope the template is created as a producer template of `access` and published, so the tenant's own template writes refuse it, and the workflow is created with the template's key, handed to the `code` manager, so panel edits outside its controls are refused (WF-4), and sent to its publication gate; the gate then runs at once outside that transaction. A run that meets a workflow another request created in the meantime leaves it to that request, and a workflow whose publication is still pending answers `service_unavailable`, so the sender tries again.
  """

  alias Relay.Actor
  alias Relay.Api.Courier.Catalog
  alias Relay.Api.Store
  alias Relay.TemplateStore

  @actor %Actor{kind: :system, ref: "relay:access_courier", on_behalf_of_ref: "relay"}
  @product "access"
  @gate %{
    variables: %{"always" => [], "conditional" => []},
    measures: %{},
    findings: [],
    accept_warnings: false
  }

  # E-108
  # E-35
  # WF-6
  @doc "Makes sure the published workflow and the live template of an entry exist in the scope; called outside any transaction."
  @spec ensure(Relay.Scope.t(), Catalog.entry()) :: :ok | {:error, Relay.Error.t()}
  def ensure(%Relay.Scope{} = scope, %{key: key} = entry) do
    case Relay.Workflow.resolve_published(scope, key) do
      {:ok, {:ok, _workflow}} -> :ok
      {:ok, :not_found} -> create(scope, entry)
      {:ok, :not_published} -> {:error, pending()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp create(scope, entry) do
    work = fn _status ->
      :ok = template(entry)
      workflow(scope, entry)
    end

    case Store.in_scope(scope, work) do
      {:ok, {:pending, version_id}} -> gate(scope, version_id)
      {:ok, :exists} -> :ok
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp template(%{key: key} = entry) do
    case TemplateStore.template(key, nil) do
      nil -> template_create(entry)
      %{"owner_product" => @product, "live_version_id" => <<_::128>>} -> :ok
      %{"owner_product" => @product, "version" => version} -> template_publish(key, version)
      _other -> Store.rollback(:template_conflict)
    end
  end

  defp template_create(entry) do
    attrs = %{
      id: Relay.Id.generate(),
      version_id: Relay.Id.generate(),
      key: entry.key,
      subtenant_id: nil,
      product: @product,
      name: "Access " <> String.replace(entry.name, "_", " "),
      category: entry.category,
      definition: Catalog.template(entry)
    }

    case TemplateStore.template_create(attrs, digest("template.created", entry.key), @actor) do
      {:created, _id, _version_id, version} -> template_publish(entry.key, version)
      {other, _id, _version_id, _version} -> Store.rollback({:template, other})
    end
  end

  defp template_publish(key, version) do
    at = %{key: key, subtenant_id: nil, product: @product}
    digest = digest("template.published", key)

    case TemplateStore.template_publish(at, @gate, version, digest, @actor) do
      {:published, _version_id, _version_no, _version} -> :ok
      {other, _version_id, _version_no, _version} -> Store.rollback({:template, other})
    end
  end

  defp workflow(scope, entry) do
    definition = Catalog.workflow(entry)

    case Relay.Workflow.create(scope, entry.key, definition, @actor) do
      {:ok, {:created, _id, _draft}} -> publication(scope, entry.key)
      {:ok, {:key_conflict, _id, _other}} -> :exists
      {:ok, {other, _id, _detail}} -> Store.rollback({:workflow, other})
    end
  end

  # WF-4
  defp publication(scope, key) do
    {:ok, _managed} = Relay.Workflow.set_manager(scope, key, "code", nil, @actor)

    case Relay.Workflow.request_publication(scope, key, nil, nil, @actor) do
      {:ok, {:pending, version_id}} -> {:pending, version_id}
      {:ok, other} -> Store.rollback({:publication, other})
    end
  end

  defp gate(scope, version_id) do
    case Relay.Workflow.run_gate(scope, version_id) do
      {:ok, {:published, _detail}} -> :ok
      {:ok, {:not_pending, _detail}} -> :ok
      _rejected_or_failed -> {:error, unavailable()}
    end
  end

  defp digest(action, key),
    do: :crypto.hash(:sha256, "relay.access_courier:" <> action <> ":" <> key)

  defp pending do
    message = "the protected workflow of this message type is being published"
    Relay.Error.new(:service_unavailable, message, %{retry_after: 5})
  end

  defp unavailable do
    message = "the protected workflow of this message type could not be prepared"
    Relay.Error.new(:service_unavailable, message, %{retry_after: 5})
  end
end
