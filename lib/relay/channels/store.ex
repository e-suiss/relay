defmodule Relay.Channels.Store do
  @moduledoc """
  Data access of the channels: provider accounts, sender identities and channel identities (C-25, C-26, C-45), the soft disable of an address after a permanent target failure (CH-11) and the `provider.unknown_code` event (CH-8). Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`; writes call the `relay_fn` functions.
  """

  alias Relay.Actor
  alias Relay.Repo

  @type id :: Relay.Id.t()
  @type digest :: <<_::256>>

  @account_columns "tenant_id, environment, id, channel, provider, ownership, credential_ref_id, role, priority, weight, state, verification_state, verified_at, verification_rule_id, in_installation, processing_countries, transfer_basis, scc_notified_on, health, settings, version"

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # C-45
  # MD-4
  @doc "Creates or changes a provider account; a change of its provider, channel, ownership, credential or settings resets its verification."
  @spec account_put(map(), digest(), Actor.t()) ::
          {:created
           | :updated
           | :unchanged
           | :not_found
           | :version_conflict
           | :credential_not_found
           | :tenant_inactive, pos_integer() | nil}
  def account_put(a, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.provider_account_put",
        [
          a.id,
          a.channel,
          a.provider,
          a.ownership,
          Map.get(a, :credential_ref_id),
          a.role,
          a.priority,
          Map.get(a, :weight, 0),
          Map.get(a, :in_installation, false),
          Map.get(a, :processing_countries, []),
          a.transfer_basis,
          Map.get(a, :scc_notified_on),
          Map.get(a, :settings, %{}),
          Map.get(a, :expected_version),
          digest
        ] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [
       :created,
       :updated,
       :unchanged,
       :not_found,
       :version_conflict,
       :credential_not_found,
       :tenant_inactive
     ]), row["version"]}
  end

  # CH-14
  # INV-43
  @doc "Sets the verification state of a provider account (`unverified`, `pending`, `verified` or `failed`, which needs a rule)."
  @spec account_verify(id(), String.t(), String.t() | nil, digest(), Actor.t()) ::
          :changed | :unchanged | :not_found
  def account_verify(id, state, rule_id, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.provider_account_verify",
        [id, state, rule_id, digest] ++ Actor.params(actor)
      )

    Repo.code!(row["provider_account_verify"], [:changed, :unchanged, :not_found])
  end

  # TN-26
  # TN-21
  @doc "Points a tenant-owned provider account at a new credential reference; it needs the step-up record of the change."
  @spec account_rotate_credential(id(), id(), String.t() | nil, digest(), Actor.t()) ::
          :rotated | :step_up_required | :not_tenant_owned | :credential_not_found | :not_found
  def account_rotate_credential(id, credential_ref_id, step_up_ref, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.provider_account_rotate_credential",
        [id, credential_ref_id, step_up_ref, digest] ++ Actor.params(actor)
      )

    Repo.code!(row["provider_account_rotate_credential"], [
      :rotated,
      :step_up_required,
      :not_tenant_owned,
      :credential_not_found,
      :not_found
    ])
  end

  # C-45
  @doc "Records the health of a provider account."
  @spec account_set_health(id(), String.t()) :: :updated | :unchanged | :not_found
  def account_set_health(id, health) do
    [row] = Repo.call!("relay_fn.provider_account_set_health", [id, health])
    Repo.code!(row["provider_account_set_health"], [:updated, :unchanged, :not_found])
  end

  # C-25
  @doc "Creates or changes a sender identity of a provider account."
  @spec sender_identity_put(map(), digest(), Actor.t()) ::
          {:created | :updated | :unchanged | :account_not_found | :subtenant_not_found,
           pos_integer() | nil}
  def sender_identity_put(i, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.sender_identity_put",
        [
          i.id,
          i.provider_account_id,
          Map.get(i, :subtenant_id),
          i.channel,
          i.kind,
          i.value,
          Map.get(i, :country),
          i.approval_state,
          digest
        ] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [
       :created,
       :updated,
       :unchanged,
       :account_not_found,
       :subtenant_not_found
     ]), row["version"]}
  end

  # TN-10
  @doc "Suspends a sender identity apart from its tenant, with a rule, or resumes it."
  @spec sender_identity_suspend(id(), boolean(), String.t() | nil, digest(), Actor.t()) ::
          :suspended | :resumed | :unchanged | :not_found
  def sender_identity_suspend(id, suspended?, rule_id, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.sender_identity_suspend",
        [id, suspended?, rule_id, digest] ++ Actor.params(actor)
      )

    Repo.code!(row["sender_identity_suspend"], [:suspended, :resumed, :unchanged, :not_found])
  end

  # C-26
  @doc "Creates or changes a channel identity; its secret lives in the secret backend."
  @spec channel_identity_put(map(), digest(), Actor.t()) ::
          {:created | :updated | :unchanged | :secret_not_found, pos_integer() | nil}
  def channel_identity_put(c, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.channel_identity_put",
        [c.id, c.channel, c.kind, c.app_ref, c.secret_ref_id, digest] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [:created, :updated, :unchanged, :secret_not_found]),
     row["version"]}
  end

  # C-45
  # CH-13
  @doc "The active provider accounts of a channel, by role and priority."
  @spec accounts(String.t()) :: [map()]
  def accounts(channel) do
    all(
      "SELECT #{@account_columns} FROM relay.provider_accounts WHERE channel = $1::relay.channel AND state = 'active' ORDER BY role DESC, priority, id",
      [channel]
    )
  end

  # C-25
  # TN-10
  @doc "The approved sender identities of provider accounts that are not suspended."
  @spec senders([id()]) :: [map()]
  def senders(account_ids) do
    all(
      "SELECT tenant_id, environment, id, provider_account_id, subtenant_id, channel, kind, value, country FROM relay.sender_identities WHERE provider_account_id = ANY($1::uuid[]) AND approval_state = 'approved' AND suspended_at IS NULL ORDER BY id",
      [account_ids]
    )
  end

  # CH-11
  # INV-14
  @doc "Soft disables the active address of a recipient after a permanent target failure and appends `address.disabled`."
  @spec address_disable(id(), String.t(), String.t(), String.t()) ::
          {:disabled | :not_found, id() | nil}
  def address_disable(recipient_id, kind, channel, rule_id) do
    [row] =
      Repo.call!("relay_fn.recipient_address_disable", [recipient_id, kind, channel, rule_id])

    {Repo.code!(row["result"], [:disabled, :not_found]), row["address_id"]}
  end

  # CH-8
  # INV-46
  @doc "Appends the `provider.unknown_code` event of a provider code without a mapping."
  @spec unknown_code(String.t(), String.t(), String.t()) :: :appended
  def unknown_code(provider, channel, raw_code) do
    [row] =
      Repo.call!("relay_fn.outbox_append", [
        Relay.Id.generate(),
        "provider.unknown_code",
        "provider:" <> provider,
        %{"provider" => provider, "channel" => channel, "raw_code" => raw_code},
        nil
      ])

    Repo.code!(row["result"], [:appended])
  end

  defp all(sql, params) do
    %Postgrex.Result{columns: columns, rows: rows} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
