defmodule Relay.Agents.Registry do
  @moduledoc """
  The agent recipient record (C-19, C-21, C-68, E-28, E-42, AG-5): a first-class recipient kind next to the subscriber and Relay's canonical record of an agent. It holds the agent's name, its owner, the endpoints a wake-up hint goes to (a signed webhook endpoint, an A2A push endpoint, a realtime connection), its one mailbox, its topic subscriptions and its state. The record serves delivery: it changes no authority, stands in for no human subscriber and is no human work queue.

  The record is bound to the agent's Access identity (E-29, TN-25): the recipient's external identifier is the Access Party reference, the pairwise `sub` of the agent's Access token in Relay's sector, stored encrypted and found through its blind index like a subscriber's external identifier. A credential whose `sub` is that reference is the agent's (`credential/2`). Access's `agent.suspended` and `agent.deleted` events stop delivery to the agent and the agent's own requests, and `agent.reactivated` lifts a suspension (`access_changed/4`); the mailbox is suspended with the agent and is never deleted, so its records stay under their retention rule (AG-23, INV-47). Deleting a record is a soft delete: the row stays `deleted`, its Access Party reference leaves the blind index so that the Party can be bound again, and its mailbox stays.

  A write happens in two parts, like a subscriber's: `prepare/2` runs outside any transaction and takes the blind index, the data key and the encrypted Party reference from the key store; `create/3`, `update/5` and `delete/3` run inside the caller's scoped transaction.
  """

  alias Relay.Actor
  alias Relay.Agents.RegistryStore, as: Store
  alias Relay.Scope

  @access_states %{suspended: "suspended", reactivated: "active", deleted: "deleted"}

  @type id :: Relay.Id.t()
  @type input :: %{
          party: String.t(),
          name: String.t(),
          owner_ref: String.t(),
          webhook_endpoint_id: id() | nil,
          a2a_push_endpoint_id: id() | nil,
          realtime: boolean(),
          topics: [String.t()]
        }
  @type change :: %{
          fields: [String.t()],
          name: String.t() | nil,
          owner_ref: String.t() | nil,
          webhook_endpoint_id: id() | nil,
          a2a_push_endpoint_id: id() | nil,
          realtime: boolean() | nil,
          topics: [String.t()] | nil
        }
  @type plan :: map()
  @type agent :: %{String.t() => term()}

  # C-21
  # E-29
  # TN-33
  @doc "Prepares the creation of an agent outside any transaction: its identifier, the blind index of its Access Party reference, its data key and the encrypted reference."
  @spec prepare(Scope.t(), input()) :: {:ok, plan()} | {:error, Relay.Error.t()}
  def prepare(%Scope{} = scope, %{party: party} = input) when is_binary(party) do
    id = Relay.Id.generate()

    with {:ok, {bidx_key_id, bidx}} <- Relay.Tenancy.blind_index(index(scope), party),
         {:ok, wrapping_key_id} <- Relay.Tenancy.active_tenant_key(scope, :dek_wrap),
         {:ok, %{wrapped_dek: wrapped, data_key: key}} <-
           Relay.Tenancy.generate_subject_key(scope, wrapping_key_id, id, :recipient_profile),
         {:ok, party_ct} <- Relay.Tenancy.encrypt_field(field(scope, id), party, data_key: key) do
      {:ok,
       %{
         id: id,
         party: party,
         party_bidx: bidx,
         bidx_key_id: bidx_key_id,
         party_ct: party_ct,
         profile_dek_id: Relay.Id.generate(),
         wrapped_dek: wrapped,
         wrapping_key_id: wrapping_key_id,
         name: input.name,
         owner_ref: input.owner_ref,
         webhook_endpoint_id: input.webhook_endpoint_id,
         a2a_push_endpoint_id: input.a2a_push_endpoint_id,
         realtime: input.realtime,
         topics: input.topics
       }}
    end
  end

  # C-21
  # E-28
  # E-29
  # C-68
  @doc "Creates a prepared agent inside the caller's scoped transaction, with its one mailbox and its topic subscriptions; returns `{:created, agent}` or the refusal: `:party_conflict` (the Access Party is bound to another record), `:endpoint_not_found`, `:topic_not_found`, `:topic_archived` or `:tenant_inactive`."
  @spec create(plan(), <<_::256>>, Actor.t()) :: {:created, agent()} | {atom(), nil}
  def create(plan, digest, %Actor{} = actor) do
    case Store.create(plan, digest, actor) do
      {:created, id, _mailbox_id} -> {:created, with_party(Store.get(id), plan.party)}
      {refusal, _id, _mailbox_id} -> {refusal, nil}
    end
  end

  # C-21
  # E-28
  @doc "Changes the named fields of an agent inside the caller's scoped transaction, under an optional expected version; returns `{:updated, agent}` (without its Access Party reference) or the refusal with the stored version: `:version_conflict`, `:not_found`, `:deleted`, `:endpoint_not_found`, `:topic_not_found` or `:topic_archived`."
  @spec update(id(), change(), pos_integer() | nil, <<_::256>>, Actor.t()) ::
          {:updated, agent()} | {atom(), pos_integer() | nil}
  def update(id, change, expected_version, digest, %Actor{} = actor) do
    case Store.update(id, change, expected_version, digest, actor) do
      {:updated, _version} -> {:updated, Store.get(id)}
      {refusal, version} -> {refusal, version}
    end
  end

  # AG-5
  # AG-23
  # INV-47
  @doc "Soft-deletes an agent inside the caller's scoped transaction: the record stays as `deleted`, its mailbox is suspended and kept, and nothing is removed. Returns `{:deleted | :unchanged, agent}` (without its Access Party reference) or `{:not_found, nil}`."
  @spec delete(id(), <<_::256>>, Actor.t()) ::
          {:deleted | :unchanged, agent()} | {:not_found, nil}
  def delete(id, digest, %Actor{} = actor) do
    case Store.set_state(id, nil, "deleted", nil, digest, actor) do
      {:not_found, _id, _version} -> {:not_found, nil}
      {:deleted, _id, _version} -> {:deleted, Store.get(id)}
      {_unchanged, _id, _version} -> {:unchanged, Store.get(id)}
    end
  end

  # C-21
  # E-28
  @doc "Reads an agent with its Access Party reference, decrypted outside the transaction, or `nil`."
  @spec get(Scope.t(), id()) :: {:ok, agent() | nil} | {:error, term()}
  def get(%Scope{} = scope, id) do
    with {:ok, row} <- Store.in_scope(scope, fn _status -> Store.get(id) end),
         do: {:ok, row && opened(scope, row)}
  end

  # C-21
  # API-56
  @doc "Lists agents from a decoded cursor, newest first, deleted ones included; at most `limit + 1` come back."
  @spec list(Scope.t(), map() | nil, pos_integer()) :: {:ok, [agent()]} | {:error, term()}
  def list(%Scope{} = scope, cursor, limit) do
    with {:ok, rows} <- Store.in_scope(scope, fn _status -> Store.list(cursor, limit) end),
         do: {:ok, Enum.map(rows, &opened(scope, &1))}
  end

  # E-29
  # AG-5
  # TN-25
  @doc "The agent whose Access Party reference is `subject`, the `sub` of a verified Access token: its identifier and state, or `nil` when no record of `scope` is bound to it."
  @spec credential(Scope.t(), String.t() | nil) ::
          {:ok, %{id: id(), state: String.t()} | nil} | {:error, term()}
  def credential(%Scope{} = scope, subject) when is_binary(subject) and subject != "" do
    case digests(scope, subject) do
      {:ok, bidxs} -> Store.in_scope(scope, fn _status -> Store.by_party(bidxs) end)
      {:error, %Relay.Error{code: :blind_index_key_unavailable}} -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end

  def credential(%Scope{}, _subject), do: {:ok, nil}

  # AG-5
  # E-29
  @doc "The state of an agent (`active`, `suspended` or `deleted`), or `nil` when there is none. Nothing is delivered to an agent that is not `active` and no request of its own is served."
  @spec state(Scope.t(), id()) :: {:ok, String.t() | nil} | {:error, term()}
  def state(%Scope{} = scope, id), do: Store.in_scope(scope, fn _status -> Store.state(id) end)

  # E-29
  # AG-5
  # AG-23
  # INV-47
  @doc "Reflects an Access agent lifecycle event on the agent of `scope` bound to the Access Party `subject`: `:suspended` and `:deleted` stop delivery to it and its own requests and suspend its mailbox, which is kept; `:reactivated` lifts a suspension. A scope without such an agent is left as it is. `event_ref` is the event's SET `jti`."
  @spec access_changed(Scope.t(), :suspended | :reactivated | :deleted, String.t(), String.t()) ::
          :ok | {:error, term()}
  def access_changed(%Scope{} = scope, kind, subject, event_ref)
      when is_map_key(@access_states, kind) and is_binary(subject) and is_binary(event_ref) do
    {:ok, actor} = Actor.new(:access, "access", "access", event_ref)
    state = Map.fetch!(@access_states, kind)
    digest = digest(scope, "agent." <> Atom.to_string(kind), event_ref)

    case digests(scope, subject) do
      {:ok, bidxs} ->
        work = fn _status -> Store.set_state(nil, bidxs, state, event_ref, digest, actor) end
        applied(Store.in_scope(scope, work))

      {:error, %Relay.Error{code: :blind_index_key_unavailable}} ->
        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  defp applied({:ok, {_result, _id, _version}}), do: :ok
  defp applied({:error, %Relay.Error{code: :not_found}}), do: :ok
  defp applied({:error, error}), do: {:error, error}

  # TN-48
  @doc "A record digest over an action, the scope and a reference."
  @spec digest(Scope.t(), String.t(), String.t()) :: <<_::256>>
  def digest(%Scope{} = scope, action, ref) do
    environment = Atom.to_string(scope.environment)
    canonical = Relay.Canonical.encode!([action, {:bytes, scope.tenant_id}, environment, ref])
    :crypto.hash(:sha256, canonical)
  end

  defp digests(scope, subject) do
    with {:ok, entries} <- Relay.Tenancy.blind_index_digests(index(scope), subject),
         do: {:ok, Enum.map(entries, &elem(&1, 1))}
  end

  defp opened(scope, row), do: with_party(row, party(scope, row))

  defp with_party(row, party),
    do: row |> Map.delete("external_id_ct") |> Map.put("access_party", party)

  defp party(_scope, %{"external_id_ct" => nil}), do: nil

  defp party(scope, %{"id" => id, "external_id_ct" => ct}) do
    case Relay.Tenancy.decrypt_field(field(scope, id), ct) do
      {:ok, value} -> Relay.Redacted.expose(value)
      {:error, _error} -> nil
    end
  end

  defp index(scope),
    do: %{tenant_id: scope.tenant_id, environment: scope.environment, purpose: "external_id"}

  defp field(scope, id) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: id,
      retention_class: :recipient_profile,
      table: "recipients",
      column: "external_id_ct"
    }
  end
end
