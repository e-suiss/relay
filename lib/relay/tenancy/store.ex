defmodule Relay.Tenancy.Store do
  @moduledoc """
  Data access for tenants, sub-tenants, settings, recipients and the tenant's key records. Writes call the `relay_fn` functions; every function except `tenant_create/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @type digest :: <<_::256>>

  # TN-1
  # TN-2
  # TN-13 (4)
  @doc "Creates a tenant through the tenant bootstrap escape hatch; no tenant context can exist before it."
  @spec tenant_create(map(), Actor.t()) ::
          {:created | :exists | :conflict | :region_mismatch, Relay.Id.t() | nil}
  def tenant_create(attrs, %Actor{} = actor) do
    [row] =
      Repo.call_unscoped!(
        :tenant_bootstrap,
        "relay_ops.tenant_create",
        [
          attrs.id,
          attrs.access_tenant_id,
          Relay.Region.dump(attrs.region),
          Map.get(attrs, :sector, "general"),
          attrs.default_timezone,
          attrs.default_locale,
          attrs.record_digest
        ] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [:created, :exists, :conflict, :region_mismatch]),
     row["tenant_id"]}
  end

  # TN-10
  @doc "Changes the tenant status in the established scope."
  @spec tenant_set_status(String.t(), String.t() | nil, integer(), digest(), Actor.t()) ::
          {:changed | :unchanged | :invalid_transition | :version_conflict, integer() | nil}
  def tenant_set_status(status, reason, expected_version, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.tenant_set_status",
        [status, reason, expected_version, digest] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [:changed, :unchanged, :invalid_transition, :version_conflict]),
     row["version"]}
  end

  # TN-2
  @doc "Updates the tenant's default time zone, locale and sector; the region never changes."
  @spec tenant_update_defaults(map(), integer(), digest(), Actor.t()) ::
          {:updated | :unchanged | :version_conflict, integer() | nil}
  def tenant_update_defaults(attrs, expected_version, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.tenant_update_defaults",
        [attrs.default_timezone, attrs.default_locale, attrs.sector, expected_version, digest] ++
          Actor.params(actor)
      )

    {Repo.code!(row["result"], [:updated, :unchanged, :version_conflict]), row["version"]}
  end

  @doc "Reads the tenant row the established scope can see."
  @spec tenant() :: map() | nil
  def tenant do
    "SELECT id, kind, access_tenant_id, region, sector, default_timezone, default_locale, status, status_reason, version FROM relay.tenants"
    |> Repo.scoped_query!([])
    |> rows()
    |> List.first()
  end

  # TN-3
  # TN-6
  @doc "Creates or updates the sub-tenant mapped from an Access organization, in the scope's environment."
  @spec subtenant_upsert(map(), digest(), Actor.t()) ::
          {:created | :updated | :unchanged | :archived, Relay.Id.t() | nil, integer() | nil}
  def subtenant_upsert(attrs, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.subtenant_upsert",
        [attrs.id, attrs.access_organization_id, attrs.name, digest] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [:created, :updated, :unchanged, :archived]), row["subtenant_id"],
     row["version"]}
  end

  @doc "Archives a sub-tenant."
  @spec subtenant_archive(Relay.Id.t(), digest(), Actor.t()) ::
          :archived | :already_archived | :not_found
  def subtenant_archive(subtenant_id, digest, %Actor{} = actor) do
    [row] =
      Repo.call!("relay_fn.subtenant_archive", [subtenant_id, digest] ++ Actor.params(actor))

    Repo.code!(row["subtenant_archive"], [:archived, :already_archived, :not_found])
  end

  # TN-4
  @doc "Sets or clears a setting at tenant level (`nil` sub-tenant) or at sub-tenant level."
  @spec setting_set(Relay.Id.t() | nil, String.t(), term(), integer() | nil, digest(), Actor.t()) ::
          {:created | :updated | :unchanged | :cleared | :version_conflict | :subtenant_not_found,
           integer() | nil}
  def setting_set(subtenant_id, key, value, expected_version, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.setting_set",
        [subtenant_id, key, value, expected_version, digest] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [
       :created,
       :updated,
       :unchanged,
       :cleared,
       :version_conflict,
       :subtenant_not_found
     ]), row["version"]}
  end

  # TN-4
  @doc "Resolves settings: sub-tenant value, then tenant value, then tenant defaults, then none."
  @spec setting_resolve(Relay.Id.t() | nil, [String.t()]) :: [
          {String.t(), term(), :subtenant | :tenant | :tenant_defaults | :none}
        ]
  def setting_resolve(subtenant_id, keys) when is_list(keys) do
    for row <- Repo.call!("relay_fn.setting_resolve", [subtenant_id, keys]) do
      {row["key"], row["value"],
       Repo.code!(row["source"], [:subtenant, :tenant, :tenant_defaults, :none])}
    end
  end

  # C-19
  # C-20
  # TN-33
  @doc "Creates a recipient with its `recipient_profile` data key in one call."
  @spec recipient_create(map()) :: {:created | :exists | :tenant_inactive, Relay.Id.t() | nil}
  def recipient_create(attrs) do
    [row] =
      Repo.call!("relay_fn.recipient_create", [
        attrs.id,
        Atom.to_string(attrs.kind),
        attrs.external_id_bidx,
        attrs.bidx_key_id,
        attrs.external_id_ct,
        attrs.profile_dek_id,
        attrs.profile_wrapped_dek,
        attrs.wrapping_key_id
      ])

    {Repo.code!(row["result"], [:created, :exists, :tenant_inactive]), row["recipient_id"]}
  end

  # TN-27
  @doc "Registers a tenant key wrapped under the region key encryption key."
  @spec tenant_key_register(map(), digest(), Actor.t()) :: :created | :exists | :active_exists
  def tenant_key_register(attrs, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.tenant_key_register",
        [
          attrs.id,
          Atom.to_string(attrs.purpose),
          Map.get(attrs, :valid_day),
          attrs.kek_ref,
          attrs.wrapped_key,
          digest
        ] ++ Actor.params(actor)
      )

    Repo.code!(row["tenant_key_register"], [:created, :exists, :active_exists])
  end

  # TN-65
  @doc "Registers the tenant's blind index key by its key store reference."
  @spec blind_index_key_register(Relay.Id.t(), String.t(), digest(), Actor.t()) ::
          :created | :exists | :active_exists
  def blind_index_key_register(id, hsm_ref, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.blind_index_key_register",
        [id, hsm_ref, digest] ++ Actor.params(actor)
      )

    Repo.code!(row["blind_index_key_register"], [:created, :exists, :active_exists])
  end

  # TN-27
  @doc "Reads the identifier of the established scope's active tenant key of a purpose."
  @spec active_tenant_key(String.t()) :: Relay.Id.t() | nil
  def active_tenant_key(purpose) when purpose in ["data", "dek_wrap"] do
    """
    SELECT tenant_id, environment::text AS environment, id
    FROM relay.tenant_keys
    WHERE state = 'active' AND purpose = $1
    """
    |> Repo.scoped_query!([purpose])
    |> rows()
    |> Enum.map(& &1["id"])
    |> List.first()
  end

  # TN-67 (1)
  @doc "Names the keys the established scope already has: `:data` and `:dek_wrap` for an active tenant key of that purpose, `:blind_index` for an active or rotating blind index key."
  @spec active_key_purposes() :: [:data | :dek_wrap | :blind_index]
  def active_key_purposes do
    """
    SELECT tenant_id, environment::text AS environment, purpose
    FROM relay.tenant_keys
    WHERE state = 'active' AND purpose IN ('data', 'dek_wrap')
    UNION ALL
    SELECT tenant_id, environment::text AS environment, 'blind_index' AS purpose
    FROM relay.blind_index_keys
    WHERE state IN ('active', 'rotating')
    """
    |> Repo.scoped_query!([])
    |> rows()
    |> Enum.map(&Repo.code!(&1["purpose"], [:data, :dek_wrap, :blind_index]))
    |> Enum.uniq()
  end

  # TN-33 (3)
  # TN-65 (2)
  @doc "Reads the readable blind index keys of the established scope: the active key first, then a key being rotated in."
  @spec blind_index_keys() :: [%{id: Relay.Id.t(), hsm_ref: String.t()}]
  def blind_index_keys do
    """
    SELECT tenant_id, environment::text AS environment, id, hsm_ref
    FROM relay.blind_index_keys
    WHERE state IN ('active', 'rotating')
    ORDER BY CASE state WHEN 'active' THEN 0 ELSE 1 END, created_at
    """
    |> Repo.scoped_query!([])
    |> rows()
    |> Enum.map(&%{id: &1["id"], hsm_ref: &1["hsm_ref"]})
  end

  # TN-27
  # OP-18
  @doc "Reads the data key record of a subject and retention class together with the tenant key that wraps it."
  @spec subject_key(Relay.Id.t(), String.t()) :: map() | nil
  def subject_key(recipient_id, retention_class) do
    """
    SELECT k.tenant_id, k.environment::text AS environment, k.id, k.state, k.wrapped_dek,
      w.id AS wrapping_key_id, w.purpose, w.state AS wrapping_state, w.kek_ref, w.wrapped_key
    FROM relay.subject_keys k
    JOIN relay.tenant_keys w
      ON w.tenant_id = k.tenant_id AND w.environment = k.environment AND w.id = k.wrapping_key_id
    WHERE k.recipient_id = $1 AND k.retention_class::text = $2
    """
    |> Repo.scoped_query!([recipient_id, retention_class])
    |> rows()
    |> List.first()
  end

  # TN-27
  @doc "Reads a tenant key record."
  @spec tenant_key(Relay.Id.t()) :: map() | nil
  def tenant_key(key_id) do
    """
    SELECT tenant_id, environment::text AS environment, id, purpose, state, kek_ref, wrapped_key
    FROM relay.tenant_keys
    WHERE id = $1
    """
    |> Repo.scoped_query!([key_id])
    |> rows()
    |> List.first()
  end

  defp rows(%Postgrex.Result{columns: columns, rows: rows}),
    do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
end
