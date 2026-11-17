defmodule Relay.Api.Agents do
  @moduledoc """
  Agent recipient records on the server API (C-21, E-28, E-29, AG-5): list, create (`201`), read, change (JSON Merge Patch under `If-Match`) and soft-delete an agent. A record names the agent, its owner, the endpoints a wake-up hint goes to, its topic subscriptions and its mandatory Access binding; it has one mailbox from the start. It serves delivery and changes no authority. Its state follows Access and is never written here: `agent.suspended` and `agent.deleted` stop delivery to the agent and its own requests, and the mailbox is kept in every state (AG-23, INV-47).

  `credential/2` resolves the agent of a verified credential that holds agent scopes (AG-6): only an active record bound to the token's Access Party makes it an agent's credential.
  """

  alias Relay.Api.Page
  alias Relay.Api.Pagination
  alias Relay.Api.Subscribers
  alias Relay.Api.Views
  alias Relay.Scope

  @endpoints ~w(webhook_endpoint_id a2a_push_endpoint_id)

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}
  @type prepared :: %{id: Relay.Id.t(), party: String.t() | nil, change: map() | nil}

  # C-21
  # E-28
  @doc "The API view of an agent row."
  @spec view(map()) :: map()
  def view(a) do
    %{
      "object" => "agent",
      "id" => Views.id("agt", a["id"]),
      "name" => a["name"],
      "owner_ref" => a["owner_ref"],
      "access" => %{"party" => a["access_party"]},
      "endpoints" => %{
        "webhook_endpoint_id" => Views.id("whe", a["webhook_endpoint_id"]),
        "a2a_push_endpoint_id" => Views.id("whe", a["a2a_push_endpoint_id"]),
        "realtime" => a["realtime"]
      },
      "mailbox" => %{"id" => Views.id("mbx", a["mailbox_id"]), "state" => a["mailbox_state"]},
      "topics" => a["topics"],
      "state" => a["state"],
      "suspended_at" => a["suspended_at"],
      "deleted_at" => a["deleted_at"],
      "version" => a["version"],
      "created_at" => a["created_at"],
      "updated_at" => a["updated_at"]
    }
  end

  # C-21
  # E-29
  @doc "Prepares the creation of an agent outside any transaction; see `Relay.Agents.Registry.prepare/2`."
  @spec prepare(Scope.t(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def prepare(%Scope{} = scope, body) do
    endpoints = Map.get(body, "endpoints", %{})

    with {:ok, webhook} <- endpoint(endpoints, "webhook_endpoint_id"),
         {:ok, a2a_push} <- endpoint(endpoints, "a2a_push_endpoint_id") do
      Relay.Agents.prepare_agent(scope, %{
        party: body["access"]["party"],
        name: body["name"],
        owner_ref: body["owner_ref"],
        webhook_endpoint_id: webhook,
        a2a_push_endpoint_id: a2a_push,
        realtime: Map.get(endpoints, "realtime", false),
        topics: Map.get(body, "topics", [])
      })
    end
  end

  # C-21
  # E-28
  # C-68
  @doc "Creates a prepared agent inside the request's transaction; `201` with its view."
  @spec create(Scope.t(), map(), Relay.Actor.t()) :: answer()
  def create(%Scope{} = scope, plan, actor) do
    digest = Relay.Agents.agent_digest(scope, "agent.created", Relay.Id.to_string(plan.id))

    case Relay.Agents.create_agent(plan, digest, actor) do
      {:created, agent} ->
        view = view(agent)
        headers = [{"location", "/v1/agents/" <> view["id"]}, Subscribers.etag(view["version"])]
        {:ok, {201, headers, view}}

      {:party_conflict, nil} ->
        {:error, Relay.Error.new(:resource_conflict, "the Access Party is bound to an agent")}

      {:tenant_inactive, nil} ->
        {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}

      {refusal, nil} ->
        {:error, invalid(refusal)}
    end
  end

  # C-21
  @doc "Reads an agent."
  @spec get(Scope.t(), Relay.Id.t()) :: answer()
  def get(%Scope{} = scope, id) do
    with {:ok, agent} <- current(scope, id), do: answered(agent)
  end

  # C-21
  # API-56
  @doc "Lists agents."
  @spec list(Scope.t(), Pagination.page(), String.t()) :: answer()
  def list(%Scope{} = scope, page, endpoint) do
    case Relay.Agents.list_agents(scope, page.cursor, page.limit) do
      {:ok, rows} ->
        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &view/1, &position/1),
             do: {:ok, {200, [], body}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # C-21
  # E-28
  @doc "Prepares a change of an agent outside any transaction: the agent as it is and the fields the merge patch names. The Access binding and the state are not among them."
  @spec prepare_update(Scope.t(), Relay.Id.t(), map()) ::
          {:ok, prepared()} | {:error, Relay.Error.t()}
  def prepare_update(%Scope{} = scope, id, body) do
    with {:ok, agent} <- current(scope, id),
         {:ok, change} <- change(body) do
      {:ok, %{id: id, party: agent["access_party"], change: change}}
    end
  end

  # C-21
  # E-28
  # T-59 (7)
  @doc "Applies a prepared change inside the request's transaction under the expected version."
  @spec update(Scope.t(), prepared(), pos_integer() | nil, Relay.Actor.t()) :: answer()
  def update(%Scope{} = scope, %{id: id, change: change} = prepared, expected_version, actor) do
    digest = Relay.Agents.agent_digest(scope, "agent.updated", Relay.Id.to_string(id))

    case Relay.Agents.update_agent(id, change, expected_version, digest, actor) do
      {:updated, agent} ->
        answered(Map.put(agent, "access_party", prepared.party))

      {:version_conflict, _version} ->
        {:error, Relay.Error.new(:precondition_failed, "the agent changed; read it again")}

      {:not_found, _version} ->
        {:error, not_found()}

      {:deleted, _version} ->
        {:error, Relay.Error.new(:resource_conflict, "the agent is deleted")}

      {refusal, _version} ->
        {:error, invalid(refusal)}
    end
  end

  # AG-5
  # AG-23
  # INV-47
  @doc "Prepares the deletion of an agent outside any transaction: the agent as it is."
  @spec prepare_delete(Scope.t(), Relay.Id.t()) :: {:ok, prepared()} | {:error, Relay.Error.t()}
  def prepare_delete(%Scope{} = scope, id) do
    with {:ok, agent} <- current(scope, id),
         do: {:ok, %{id: id, party: agent["access_party"], change: nil}}
  end

  # AG-5
  # AG-23
  # INV-47
  @doc "Soft-deletes an agent inside the request's transaction; its mailbox is kept. Deleting a deleted agent returns it."
  @spec delete(Scope.t(), prepared(), Relay.Actor.t()) :: answer()
  def delete(%Scope{} = scope, %{id: id} = prepared, actor) do
    digest = Relay.Agents.agent_digest(scope, "agent.deleted", Relay.Id.to_string(id))

    case Relay.Agents.delete_agent(id, digest, actor) do
      {:not_found, nil} -> {:error, not_found()}
      {_result, agent} -> answered(Map.put(agent, "access_party", prepared.party))
    end
  end

  # AG-6
  # E-29
  # AG-5
  @doc "The active agent bound to the Access Party `subject` of a verified credential that holds agent scopes; an unregistered, suspended or deleted agent is `auth_agent_inactive`."
  @spec credential(Scope.t(), String.t() | nil) :: {:ok, Relay.Id.t()} | {:error, Relay.Error.t()}
  def credential(%Scope{} = scope, subject) do
    case Relay.Agents.agent_credential(scope, subject) do
      {:ok, %{id: id, state: "active"}} -> {:ok, id}
      {:ok, _unbound_or_inactive} -> {:error, inactive()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp current(scope, id) do
    case Relay.Agents.get_agent(scope, id) do
      {:ok, %{} = agent} -> {:ok, agent}
      {:ok, nil} -> {:error, not_found()}
      {:error, %Relay.Error{code: :not_found}} -> {:error, not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp answered(agent) do
    view = view(agent)
    {:ok, {200, [Subscribers.etag(view["version"])], view}}
  end

  defp change(body) do
    endpoints = Map.get(body, "endpoints", %{})
    named = Enum.filter(@endpoints ++ ["realtime"], &Map.has_key?(endpoints, &1))

    with {:ok, webhook} <- endpoint(endpoints, "webhook_endpoint_id"),
         {:ok, a2a_push} <- endpoint(endpoints, "a2a_push_endpoint_id") do
      {:ok,
       %{
         fields: Enum.filter(~w(name owner_ref topics), &Map.has_key?(body, &1)) ++ named,
         name: body["name"],
         owner_ref: body["owner_ref"],
         webhook_endpoint_id: webhook,
         a2a_push_endpoint_id: a2a_push,
         realtime: endpoints["realtime"],
         topics: body["topics"]
       }}
    end
  end

  defp endpoint(endpoints, name) do
    case Map.get(endpoints, name) do
      nil ->
        {:ok, nil}

      text ->
        case Relay.ExternalId.decode(text, ["whe"]) do
          {:ok, id} -> {:ok, id}
          {:error, _error} -> {:error, invalid(:endpoint_not_found)}
        end
    end
  end

  defp invalid(:endpoint_not_found),
    do: field_error("/endpoints", "not_found", "no webhook endpoint has this id")

  defp invalid(:topic_not_found),
    do: field_error("/topics", "not_found", "no topic has this key")

  defp invalid(:topic_archived),
    do: field_error("/topics", "not_allowed", "the topic is archived")

  defp field_error(pointer, code, detail) do
    error = %{pointer: pointer, code: code, detail: detail}
    Relay.Error.new(:validation_failed, "the agent breaks a field rule", %{errors: [error]})
  end

  defp position(row), do: {row["cursor_at"], row["id"]}

  @doc "The error of an unknown agent."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:agent_not_found, "no agent has this id")

  defp inactive,
    do: Relay.Error.new(:auth_agent_inactive, "no active agent is bound to this credential")

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
