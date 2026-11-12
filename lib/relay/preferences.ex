defmodule Relay.Preferences do
  @moduledoc """
  Categories, preferences, the consent copy and suppressions (PC-57, PC-59). Other contexts use only the functions of this module.

  * A category is unique by key in a tenant environment and keeps the message class it was created with; it is archived, never deleted. A sub-tenant overrides only `enabled`, `channel_defaults`, `frequency` and `default_expires_in` (PC-57 (1), PC-57 (2)).
  * A preference is one canonical row per recipient, level, key and channel, and every write opens a change record. A tenant writes only `opt_out`; closing the last open channel of a locked category is refused (PC-15, PC-6). The profile (quiet hours, schedule, do not disturb, digest choices) is written only by the subscriber (PC-57 (5)).
  * The consent copy is append-only and written by Access through `consent.updated` (E-80); a revoked record of any source wins (PC-21).
  * A suppression is keyed by channel and the blind index of the address; lifting writes `lifted_at` and never deletes. A tenant lifts only `manual` and `invalid` suppressions (PC-59 (2)).

  Functions named for a write run inside the caller's scoped transaction; the others open their own.
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Access, Relay.Subscribers, Relay.Tenancy],
    exports: [AccessConsentHandler]

  alias Relay.Actor
  alias Relay.Preferences.Store
  alias Relay.Scope

  @type result(value) :: {:ok, value} | {:error, term()}

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Scope.t(), (atom() -> term())) :: result(term())
  defdelegate in_scope(scope, fun), to: Store

  # PC-57 (1)
  @doc "Creates a category inside the caller's scoped transaction; `attrs` carries `:key`, `:name`, `:message_class`, `:locked`, `:enabled`, `:channel_defaults`, `:default_expires_in`, `:frequency`, `:digest_allowed`, `:default_route` and `:density` (WF-30)."
  @spec create_category(Scope.t(), map(), Actor.t()) ::
          {atom(), Relay.Id.t() | nil, pos_integer() | nil}
  def create_category(%Scope{} = scope, attrs, %Actor{} = actor) do
    attrs = Map.put(attrs, :id, Relay.Id.generate())
    Store.category_create(attrs, digest(scope, "category.created", attrs.key), actor)
  end

  # PC-57 (1)
  # PC-11
  @doc "Writes every field of a category under its version inside the caller's scoped transaction."
  @spec update_category(Scope.t(), String.t(), map(), pos_integer() | nil, Actor.t()) ::
          {atom(), pos_integer() | nil}
  def update_category(%Scope{} = scope, key, attrs, expected_version, %Actor{} = actor) do
    digest = digest(scope, "category.updated", key)
    Store.category_update(key, attrs, expected_version, digest, actor)
  end

  # PC-57 (1)
  @doc "Archives a category inside the caller's scoped transaction."
  @spec archive_category(Scope.t(), String.t(), Actor.t()) :: {atom(), pos_integer() | nil}
  def archive_category(%Scope{} = scope, key, %Actor{} = actor),
    do: Store.category_archive(key, digest(scope, "category.archived", key), actor)

  # PC-57 (2)
  @doc "Replaces a sub-tenant's overrides of a category inside the caller's scoped transaction; `attrs` carries `:enabled`, `:channel_defaults`, `:default_expires_in` and `:frequency`."
  @spec put_subtenant_setting(Scope.t(), String.t(), Relay.Id.t(), map(), Actor.t()) ::
          {atom(), pos_integer() | nil}
  def put_subtenant_setting(%Scope{} = scope, key, subtenant_id, attrs, %Actor{} = actor) do
    ref = key <> ":" <> Relay.Id.to_string(subtenant_id)
    digest = digest(scope, "category_subtenant_setting.changed", ref)
    Store.subtenant_put(Relay.Id.generate(), key, subtenant_id, attrs, digest, actor)
  end

  @doc "Reads a category by key inside the caller's scoped transaction; `nil` when there is none."
  @spec category(String.t()) :: map() | nil
  defdelegate category(key), to: Store

  @doc "Reads a category by key; `nil` when there is none."
  @spec get_category(Scope.t(), String.t()) :: result(map() | nil)
  def get_category(%Scope{} = scope, key),
    do: Store.in_scope(scope, fn _status -> Store.category(key) end)

  # API-56
  @doc "Lists categories newest first from a decoded cursor; at most `limit + 1` rows come back."
  @spec list_categories(Scope.t(), map() | nil, pos_integer()) :: result([map()])
  def list_categories(%Scope{} = scope, cursor, limit),
    do: Store.in_scope(scope, fn _status -> Store.categories(cursor, limit) end)

  # PC-57 (2)
  @doc "Reads a sub-tenant's overrides of a category inside the caller's scoped transaction: `:not_found`, `:subtenant_not_found`, `nil` when the sub-tenant has none, or the setting."
  @spec subtenant_setting(String.t(), Relay.Id.t()) ::
          :not_found | :subtenant_not_found | map() | nil
  def subtenant_setting(key, subtenant_id) do
    case Store.category(key) do
      nil ->
        :not_found

      category ->
        if Store.subtenant?(subtenant_id),
          do: Store.subtenant_setting(category["id"], subtenant_id),
          else: :subtenant_not_found
    end
  end

  @doc "Reads a sub-tenant's overrides of a category; see `subtenant_setting/2`."
  @spec get_subtenant_setting(Scope.t(), String.t(), Relay.Id.t()) ::
          result(:not_found | :subtenant_not_found | map() | nil)
  def get_subtenant_setting(%Scope{} = scope, key, subtenant_id),
    do: Store.in_scope(scope, fn _status -> subtenant_setting(key, subtenant_id) end)

  # PC-57 (5)
  # PC-12
  @doc "Whether a recipient is an active subscriber, inside the caller's scoped transaction."
  @spec subscriber?(Relay.Id.t()) :: boolean()
  defdelegate subscriber?(recipient_id), to: Store

  # PC-57 (5)
  # PC-12
  @doc "A recipient's preferences inside the caller's scoped transaction: its category × channel `cells`, its channel, workflow and scope key `switches` and its `profile` (`nil` when it has none)."
  @spec preferences(Relay.Id.t()) :: %{cells: [map()], switches: [map()], profile: map() | nil}
  def preferences(recipient_id) do
    %{
      cells: Store.cells(recipient_id),
      switches: Store.switches(recipient_id),
      profile: Store.profile(recipient_id)
    }
  end

  @doc "A recipient's preferences; see `preferences/1`."
  @spec get_preferences(Scope.t(), Relay.Id.t()) :: result(map() | nil)
  def get_preferences(%Scope{} = scope, recipient_id) do
    Store.in_scope(scope, fn _status ->
      if Store.subscriber?(recipient_id), do: preferences(recipient_id)
    end)
  end

  # PC-57 (5)
  # PC-15
  # PC-6
  @doc "Writes preference switches in order inside the caller's scoped transaction as `writer` (`subscriber` or `tenant`); the first refused write stops and is returned with its index, and the caller rolls the transaction back. Each write carries `:level`, `:key`, `:channel` and `:value`."
  @spec write_preferences(Relay.Id.t(), [map()], String.t(), String.t() | nil) ::
          :ok | {:refused, atom(), non_neg_integer()}
  def write_preferences(recipient_id, writes, writer, actor_ref) do
    writes
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {write, index}, :ok ->
      write = Map.put(write, :recipient_id, recipient_id)

      case Store.preference_set(write, writer, actor_ref) do
        {result, _id, _version} when result in [:set, :unchanged] -> {:cont, :ok}
        {refused, _id, _version} -> {:halt, {:refused, refused, index}}
      end
    end)
  end

  # PC-57 (5)
  @doc "Writes the fields `changes` names over a recipient's current profile inside the caller's scoped transaction; an absent field is untouched and `digest` is replaced as a whole. Only `subscriber` and `access` write a profile."
  @spec write_profile(Relay.Id.t(), map(), String.t()) :: :ok | {:refused, atom()}
  def write_profile(recipient_id, changes, writer) do
    current = Store.profile(recipient_id) || default_profile()
    profile = Map.merge(Map.take(current, Map.keys(default_profile())), changes)

    case Store.profile_put(recipient_id, profile, writer) do
      {result, _version} when result in [:created, :updated, :unchanged] -> :ok
      {refused, _version} -> {:refused, refused}
    end
  end

  @doc "The profile of a recipient that has not written one."
  @spec default_profile() :: map()
  def default_profile do
    %{
      "quiet_hours" => [],
      "schedule" => [],
      "dnd_until" => nil,
      "quiet_hours_email" => false,
      "digest" => %{}
    }
  end

  # PC-59 (1)
  # PC-21
  @doc "The current consent of a subscriber per brand and channel; `nil` when it is not an active subscriber."
  @spec get_consents(Scope.t(), Relay.Id.t()) :: result([map()] | nil)
  def get_consents(%Scope{} = scope, recipient_id) do
    Store.in_scope(scope, fn _status ->
      if Store.subscriber?(recipient_id), do: Store.consents(recipient_id)
    end)
  end

  # PC-59 (1)
  # E-80
  @doc """
  Records a consent of a recipient in its consent copy (E-80). `attrs` carries `:recipient_id`, `:brand_subtenant_id`, `:channel`, `:status`, `:consent_kind`, `:recipient_type`, `:source`, `:sequence`, `:occurred_at`, `:text_version_digest`, `:evidence` (a map or `nil`), `:iys_transaction_ref` and `:source_event_ref`; instead of `:evidence` it may carry `:sealed`, evidence already sealed by `seal_consent_evidence/3`. The evidence is encrypted under the recipient's `commercial_consent` subject key, which is created on first use; the key store is called outside any transaction, so this function must not run inside one. An older or repeated sequence changes nothing.
  """
  @spec record_consent(Scope.t(), map()) :: result(atom())
  def record_consent(%Scope{} = scope, attrs) do
    sealing =
      case attrs do
        %{sealed: %{evidence_ct: _, evidence_key_id: _} = sealed} -> {:ok, sealed}
        _plain -> seal_evidence(scope, attrs.recipient_id, Map.get(attrs, :evidence))
      end

    with {:ok, sealed} <- sealing do
      row = Map.merge(attrs, sealed)

      Store.in_scope(scope, fn _status ->
        {result, _id} = Store.consent_record(row)
        result
      end)
    end
  end

  # PC-59 (1)
  # E-80
  @doc "Encrypts consent evidence for the consent copy of a recipient under its `commercial_consent` subject key, created on first use, so that only the ciphertext is kept until the consent is recorded; call it outside any transaction."
  @spec seal_consent_evidence(Scope.t(), Relay.Id.t(), map()) ::
          {:ok, %{evidence_ct: binary(), evidence_key_id: Relay.Id.t()}} | {:error, term()}
  def seal_consent_evidence(%Scope{} = scope, recipient_id, %{} = evidence),
    do: seal_evidence(scope, recipient_id, evidence)

  defp seal_evidence(_scope, _recipient_id, nil),
    do: {:ok, %{evidence_ct: nil, evidence_key_id: nil}}

  defp seal_evidence(scope, recipient_id, evidence) do
    field = %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: recipient_id,
      retention_class: :commercial_consent,
      table: "consents",
      column: "evidence_ct"
    }

    plaintext = Jason.encode!(evidence)

    with {:ok, key_id, opts} <- consent_key(scope, recipient_id),
         {:ok, ct} <- Relay.Tenancy.encrypt_field(field, plaintext, opts) do
      {:ok, %{evidence_ct: ct, evidence_key_id: key_id}}
    end
  end

  # OP-18
  defp consent_key(scope, recipient_id) do
    case Store.in_scope(scope, fn _status -> Store.consent_key(recipient_id) end) do
      {:ok, <<_::128>> = key_id} -> {:ok, key_id, []}
      {:ok, nil} -> new_consent_key(scope, recipient_id)
      {:error, error} -> {:error, error}
    end
  end

  defp new_consent_key(scope, recipient_id) do
    id = Relay.Id.generate()

    with {:ok, wrap_id} <- Relay.Tenancy.active_tenant_key(scope, :dek_wrap),
         {:ok, %{wrapped_dek: wrapped, data_key: data_key}} <-
           Relay.Tenancy.generate_subject_key(scope, wrap_id, recipient_id, :commercial_consent),
         {:ok, created} <- register_key(scope, id, recipient_id, wrapped, wrap_id) do
      case created do
        {:created, ^id} -> {:ok, id, [data_key: data_key]}
        {:exists, key_id} -> {:ok, key_id, []}
        {missing, _id} -> {:error, Relay.Error.new(missing, "the recipient cannot hold a key")}
      end
    end
  end

  defp register_key(scope, id, recipient_id, wrapped, wrap_id) do
    Store.in_scope(scope, fn _status ->
      Store.consent_key_create(id, recipient_id, wrapped, wrap_id)
    end)
  end

  # PC-59 (2)
  # OP-20
  @doc "The blind indexes of a suppressed address, computed outside any transaction; see `Relay.Subscribers.address_digests/3`."
  @spec address_digests(Scope.t(), String.t(), String.t()) ::
          {:ok, [{Relay.Id.t(), <<_::256>>}, ...]} | {:error, term()}
  defdelegate address_digests(scope, channel, address), to: Relay.Subscribers

  # PC-59 (2)
  @doc "Adds a manual or `invalid` suppression inside the caller's scoped transaction; `attrs` carries `:channel`, `:digests` (from `address_digests/3`), `:reason` and `:expires_at`. An equal active suppression is `:exists` and changes nothing."
  @spec add_suppression(Scope.t(), map(), Actor.t()) :: {atom(), Relay.Id.t() | nil}
  def add_suppression(%Scope{} = scope, attrs, %Actor{} = actor) do
    [{key_id, current} | rest] = attrs.digests

    row = %{
      channel: attrs.channel,
      target_digest: current,
      target_digest_key_id: key_id,
      target_digest_next: next_digest(rest),
      reason: attrs.reason,
      expires_at: attrs.expires_at
    }

    ref = attrs.channel <> ":" <> Base.encode16(current, case: :lower)
    Store.suppression_add(row, digest(scope, "suppression.added", ref), actor)
  end

  defp next_digest([{_key_id, digest} | _rest]), do: digest
  defp next_digest([]), do: nil

  # PC-59 (2)
  # TN-22
  @doc "Lifts a suppression inside the caller's scoped transaction; `lift` carries `:lifter` (`tenant` or `operator`), `:step_up_ref` and `:reason`."
  @spec lift_suppression(Scope.t(), Relay.Id.t(), map(), Actor.t()) :: atom()
  def lift_suppression(%Scope{} = scope, id, lift, %Actor{} = actor) do
    digest = digest(scope, "suppression.lifted", Relay.Id.to_string(id))
    Store.suppression_lift(id, lift, digest, actor)
  end

  @doc "Reads a suppression inside the caller's scoped transaction; `nil` when there is none."
  @spec suppression(Relay.Id.t()) :: map() | nil
  defdelegate suppression(id), to: Store

  # API-56
  @doc "Lists suppressions newest first from a decoded cursor with `filters` (`:channel`, `:reason`, `:state`); at most `limit + 1` rows come back."
  @spec list_suppressions(Scope.t(), map(), map() | nil, pos_integer()) :: result([map()])
  def list_suppressions(%Scope{} = scope, filters, cursor, limit),
    do: Store.in_scope(scope, fn _status -> Store.suppressions(filters, cursor, limit) end)

  defp digest(scope, action, ref) do
    environment = Atom.to_string(scope.environment)

    :crypto.hash(
      :sha256,
      Relay.Canonical.encode!([action, {:bytes, scope.tenant_id}, environment, ref])
    )
  end
end
