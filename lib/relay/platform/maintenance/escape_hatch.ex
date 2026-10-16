defmodule Relay.Platform.Maintenance.EscapeHatch do
  @moduledoc """
  The one place where Relay works across tenants. Every call goes through `Relay.Platform.MaintRepo` as `relay_maint`, the BYPASSRLS maintenance role, and reads or writes only installation tables, catalog data and identifiers: partition maintenance, the audit Merkle log, the integrity check and the discovery of keys due for destruction. Tenant data itself is changed only through tenant-scoped `relay_fn` functions under the tenant's own context.

  `DETACH PARTITION … CONCURRENTLY` cannot run inside a function or a transaction block, so it runs here on one checked-out connection between `SET ROLE relay_migrator` and `RESET ROLE`; no other module sets a role.
  """

  alias Relay.Platform.MaintRepo

  @ident ~r/^[a-z_][a-z0-9_]{0,62}$/

  @type policy :: %{
          table_name: String.t(),
          interval: :day | :month,
          premake: Postgrex.Interval.t(),
          alarm: Postgrex.Interval.t(),
          hot_retention: Postgrex.Interval.t()
        }

  @type result :: {:ok, term()} | {:error, Relay.Error.t()}

  # OP-13
  # OP-66
  @doc "Reads the partition policies."
  @spec partition_policies() :: {:ok, [policy()]} | {:error, Relay.Error.t()}
  def partition_policies do
    select(
      "SELECT table_name, partition_interval, premake_horizon, alarm_threshold, hot_retention FROM relay.partition_policies ORDER BY table_name",
      [],
      fn [table, interval, premake, alarm, hot] ->
        %{
          table_name: table,
          interval: interval(interval),
          premake: premake,
          alarm: alarm,
          hot_retention: hot
        }
      end
    )
  end

  defp interval("day"), do: :day
  defp interval("month"), do: :month

  @doc "Returns the furthest partition bound of each partitioned table and whether it clears the alarm horizon."
  @spec partition_horizon() ::
          {:ok, [%{table_name: String.t(), furthest_bound: DateTime.t() | nil, ok: boolean()}]}
          | {:error, Relay.Error.t()}
  def partition_horizon do
    select(
      "SELECT table_name, furthest_bound, ok FROM relay_ops.partition_horizon()",
      [],
      fn [table, bound, ok] -> %{table_name: table, furthest_bound: bound, ok: ok} end
    )
  end

  # OP-14
  @doc "Creates one partition of `table` for `[from, to)` with the lock-free method of `relay_private.partition_create`."
  @spec partition_create(String.t(), DateTime.t(), DateTime.t()) ::
          {:ok, String.t()} | {:error, Relay.Error.t()}
  def partition_create(table, %DateTime{} = from, %DateTime{} = to),
    do:
      one(
        "SELECT relay_private.partition_create($1, $2, $3)",
        [table, from, to]
      )

  @doc "Refreshes the statistics of a partitioned parent table."
  @spec parent_analyze(String.t()) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  def parent_analyze(table), do: one("SELECT relay_private.parent_analyze($1)", [table])

  # OP-15
  # OP-68
  @doc "Lists partitions whose hot retention has passed."
  @spec partitions_due_for_archive() ::
          {:ok,
           [%{table_name: String.t(), partition_name: String.t(), upper_bound: DateTime.t()}]}
          | {:error, Relay.Error.t()}
  def partitions_due_for_archive do
    select(
      "SELECT table_name, partition_name, upper_bound FROM relay_ops.partition_due_for_archive() ORDER BY upper_bound, table_name, partition_name",
      [],
      fn [table, partition, upper] ->
        %{table_name: table, partition_name: partition, upper_bound: upper}
      end
    )
  end

  @doc "Lists partitions of the `relay` schema whose concurrent detach was interrupted."
  @spec pending_detaches() ::
          {:ok, [%{table_name: String.t(), partition_name: String.t()}]}
          | {:error, Relay.Error.t()}
  def pending_detaches do
    select(
      """
      SELECT parent.relname, child.relname
      FROM pg_catalog.pg_inherits i
      JOIN pg_catalog.pg_class child ON child.oid = i.inhrelid
      JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent
      JOIN pg_catalog.pg_namespace n ON n.oid = parent.relnamespace
      WHERE n.nspname = 'relay' AND i.inhdetachpending
      ORDER BY parent.relname, child.relname
      """,
      [],
      fn [table, partition] -> %{table_name: table, partition_name: partition} end
    )
  end

  @doc "Lists the detached tables of the `relay` schema that are partitions no longer: the hand-off set of the archive role."
  @spec detached_partitions([String.t()]) :: {:ok, [String.t()]} | {:error, Relay.Error.t()}
  def detached_partitions(names) when is_list(names) do
    select(
      """
      SELECT c.relname
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'relay' AND c.relname = ANY($1) AND NOT c.relispartition
      ORDER BY c.relname
      """,
      [names],
      fn [name] -> name end
    )
  end

  # OP-14
  # OP-15
  @doc "Detaches a partition with `DETACH PARTITION … CONCURRENTLY`; outside any transaction."
  @spec detach(String.t(), String.t()) :: :ok | {:error, Relay.Error.t()}
  def detach(table, partition), do: as_owner(table, partition, "CONCURRENTLY")

  @doc "Completes an interrupted concurrent detach with `DETACH PARTITION … FINALIZE`."
  @spec finalize_detach(String.t(), String.t()) :: :ok | {:error, Relay.Error.t()}
  def finalize_detach(table, partition), do: as_owner(table, partition, "FINALIZE")

  defp as_owner(table, partition, mode) do
    with :ok <- ident(table),
         :ok <- ident(partition) do
      sql = "ALTER TABLE relay.#{table} DETACH PARTITION relay.#{partition} #{mode}"
      MaintRepo.checkout(fn -> with_owner_role(sql) end)
    end
  end

  defp with_owner_role(sql) do
    with :ok <- ok(MaintRepo.query("SET ROLE relay_migrator", [])) do
      try do
        sql |> MaintRepo.query([]) |> ok()
      after
        MaintRepo.query("RESET ROLE", [])
      end
    end
  end

  # OP-42
  # TN-16
  @doc "Runs the nightly orphan and composite foreign key check."
  @spec orphan_check() ::
          {:ok,
           [%{check_name: String.t(), table_name: String.t(), violations: non_neg_integer()}]}
          | {:error, Relay.Error.t()}
  def orphan_check do
    select(
      "SELECT check_name, table_name, violations FROM relay_ops.orphan_check() ORDER BY check_name, table_name",
      [],
      fn [check, table, violations] ->
        %{check_name: check, table_name: table, violations: violations}
      end
    )
  end

  # OP-63
  @doc "Appends Merkle leaves to the audit log `origin` from `first_index`, under the fencing token."
  @spec audit_leaves_append(
          String.t(),
          non_neg_integer(),
          [Relay.Id.t()],
          [binary()],
          pos_integer()
        ) ::
          {:ok, String.t()} | {:error, Relay.Error.t()}
  def audit_leaves_append(origin, first_index, audit_ids, leaf_hashes, token),
    do:
      one(
        "SELECT relay_ops.audit_leaves_append($1, $2, $3, $4, $5)",
        [origin, first_index, audit_ids, leaf_hashes, token]
      )

  @doc "Records a signed checkpoint under the fencing token."
  @spec audit_checkpoint_record(map(), pos_integer()) ::
          {:ok, String.t()} | {:error, Relay.Error.t()}
  def audit_checkpoint_record(checkpoint, token),
    do:
      one(
        "SELECT relay_ops.audit_checkpoint_record($1, $2, $3, $4, $5, $6, $7, $8)",
        [
          checkpoint.id,
          checkpoint.origin,
          checkpoint.tree_size,
          checkpoint.root_hash,
          checkpoint.signed_note,
          checkpoint.key_ref,
          checkpoint.heartbeat,
          token
        ]
      )

  @doc "Records the outcome of publishing a checkpoint to one target."
  @spec audit_checkpoint_publication_record(
          Relay.Id.t(),
          String.t(),
          String.t(),
          String.t() | nil
        ) ::
          {:ok, String.t()} | {:error, Relay.Error.t()}
  def audit_checkpoint_publication_record(checkpoint_id, target, status, detail),
    do:
      one(
        "SELECT relay_ops.audit_checkpoint_publication_record($1, $2, $3, $4)",
        [checkpoint_id, target, status, detail]
      )

  @doc "Reads up to `limit` audit records committed below the current snapshot's xmin and at or above `watermark` that have no leaf yet, with that xmin as the next watermark."
  @spec audit_pending(String.t(), pos_integer()) ::
          {:ok, [map()], String.t() | nil} | {:error, Relay.Error.t()}
  def audit_pending(watermark, limit) do
    with {:ok, rows} <-
           select(
             """
             SELECT tenant_id, environment, audit_id, created_at, txid::text, record_digest,
                    upper_xmin::text
             FROM relay_ops.audit_pending($1::text::xid8, $2)
             """,
             [watermark, limit],
             & &1
           ) do
      upper = Enum.find_value(rows, &List.last/1)
      {:ok, Enum.map(rows, &pending_row/1), upper}
    end
  end

  defp pending_row([tenant, environment, id, created_at, txid, digest, _upper]) do
    %{
      tenant_id: tenant,
      environment: environment,
      audit_id: id,
      created_at: created_at,
      txid: String.to_integer(txid),
      record_digest: digest
    }
  end

  @doc "Returns which of the given audit record ids already have a leaf."
  @spec integrated_audit_ids([Relay.Id.t()]) ::
          {:ok, MapSet.t(Relay.Id.t())} | {:error, Relay.Error.t()}
  def integrated_audit_ids([]), do: {:ok, MapSet.new()}

  def integrated_audit_ids(ids) do
    with {:ok, found} <-
           select(
             "SELECT audit_id FROM relay.audit_leaves WHERE audit_id = ANY($1)",
             [ids],
             fn [id] -> id end
           ),
         do: {:ok, MapSet.new(found)}
  end

  @doc "Reads up to `limit` leaves of the log `origin` from `from_index`, with the audit record each one commits to (`nil` fields when the record is missing)."
  @spec audit_leaves(String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, [map()]} | {:error, Relay.Error.t()}
  def audit_leaves(origin, from_index, limit) do
    select(
      """
      SELECT l.leaf_index, l.leaf_hash, l.audit_tenant_id, l.audit_environment, l.audit_id,
             l.audit_created_at, a.record_digest, a.created_at
      FROM relay.audit_leaves l
      LEFT JOIN relay.audit_log a
        ON a.tenant_id = l.audit_tenant_id AND a.environment = l.audit_environment
       AND a.id = l.audit_id AND a.created_at = l.audit_created_at
      WHERE l.log_origin = $1 AND l.leaf_index >= $2
      ORDER BY l.leaf_index
      LIMIT $3
      """,
      [origin, from_index, limit],
      fn [index, hash, tenant, environment, id, leaf_created_at, digest, record_created_at] ->
        %{
          leaf_index: index,
          leaf_hash: hash,
          tenant_id: tenant,
          environment: environment,
          audit_id: id,
          created_at: leaf_created_at,
          record_digest: digest,
          record_created_at: record_created_at
        }
      end
    )
  end

  @doc "Lists the log origins that have checkpoints."
  @spec audit_origins() :: {:ok, [String.t()]} | {:error, Relay.Error.t()}
  def audit_origins,
    do:
      select(
        "SELECT DISTINCT log_origin FROM relay.audit_checkpoints ORDER BY log_origin",
        [],
        fn [origin] -> origin end
      )

  @doc "Lists the checkpoints of a log origin by tree size."
  @spec audit_checkpoints(String.t()) :: {:ok, [map()]} | {:error, Relay.Error.t()}
  def audit_checkpoints(origin) do
    select(
      """
      SELECT id, tree_size, root_hash, signed_note, is_heartbeat
      FROM relay.audit_checkpoints WHERE log_origin = $1
      ORDER BY tree_size, created_at
      """,
      [origin],
      fn [id, size, root, note, heartbeat] ->
        %{id: id, tree_size: size, root_hash: root, signed_note: note, heartbeat: heartbeat}
      end
    )
  end

  @doc "Counts audit records below the watermark that have no leaf."
  @spec unintegrated_audit_records(String.t()) ::
          {:ok, non_neg_integer()} | {:error, Relay.Error.t()}
  def unintegrated_audit_records(watermark) do
    one(
      """
      SELECT count(*) FROM relay.audit_log a
      WHERE a.txid < $1::text::xid8
        AND NOT EXISTS (SELECT 1 FROM relay.audit_leaves l WHERE l.audit_id = a.id)
      """,
      [watermark]
    )
  end

  # OP-17
  @doc "Lists receipt day keys of every tenant whose day is on or before `last_day` and that are not destroyed yet."
  @spec receipt_day_keys_due(Date.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, Relay.Error.t()}
  def receipt_day_keys_due(%Date{} = last_day, limit) do
    select(
      "SELECT tenant_id, environment, key_id, valid_day FROM relay_ops.receipt_keys_due($1, $2)",
      [last_day, limit],
      fn [tenant, environment, id, day] ->
        %{tenant_id: tenant, environment: environment, key_id: id, valid_day: day}
      end
    )
  end

  # OP-16
  @doc "Lists subject data keys of every tenant whose retention period has ended."
  @spec retention_due(pos_integer()) :: {:ok, [map()]} | {:error, Relay.Error.t()}
  def retention_due(limit) do
    select(
      "SELECT tenant_id, environment, subject_key_id, recipient_id, retention_class, due_at FROM relay_ops.retention_due($1)",
      [limit],
      fn [tenant, environment, key, recipient, class, due] ->
        %{
          tenant_id: tenant,
          environment: environment,
          subject_key_id: key,
          recipient_id: recipient,
          retention_class: class,
          due_at: due
        }
      end
    )
  end

  defp select(sql, params, row) do
    case MaintRepo.query(sql, params) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, row)}
      other -> error(other)
    end
  end

  defp one(sql, params) do
    case MaintRepo.query(sql, params) do
      {:ok, %{rows: [[value]]}} -> {:ok, value}
      other -> error(other)
    end
  end

  defp ok({:ok, _}), do: :ok
  defp ok(other), do: error(other)

  defp error({:error, %Postgrex.Error{postgres: %{code: code}}}),
    do: {:error, Relay.Error.new(code_of(code), "maintenance query failed", %{sqlstate: code})}

  defp error({:error, %DBConnection.ConnectionError{}}),
    do: {:error, Relay.Error.new(:database_unreachable, "maintenance database unreachable")}

  defp error(_other), do: {:error, Relay.Error.new(:database_error, "maintenance query failed")}

  defp code_of(:lock_not_available), do: :lock_timeout
  defp code_of(:query_canceled), do: :statement_timeout
  defp code_of(_code), do: :database_error

  defp ident(name) do
    if is_binary(name) and Regex.match?(@ident, name),
      do: :ok,
      else: {:error, Relay.Error.new(:invalid_argument, "not a plain table name")}
  end
end
