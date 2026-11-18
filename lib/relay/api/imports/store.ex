defmodule Relay.Api.Imports.Store do
  @moduledoc """
  Data access of imports (OP-96, OP-55, OP-97): writes call the `relay_fn.import_*` functions; reads select the import row and count how many imported addresses are suppressed. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @columns """
  i.id, i.kind, i.batch, i.state, i.line_count, i.byte_size, i.content_sha256, i.content_ct,
  i.content_key_id, i.report, i.failure, i.requested_by, i.completed_at, i.created_at,
  i.updated_at
  """

  @active "s.lifted_at IS NULL AND (s.expires_at IS NULL OR s.expires_at > now())"

  @suppressed """
  SELECT count(DISTINCT a.n) FILTER (WHERE s.id IS NOT NULL AND #{@active}) AS suppressed,
    count(DISTINCT a.n) FILTER (WHERE b.id IS NOT NULL) AS expected,
    count(DISTINCT a.n) FILTER (WHERE b.id IS NOT NULL AND #{@active}) AS expected_suppressed
  FROM unnest($1::bigint[], $2::text[], $3::bytea[]) AS a(n, kind, digest)
  LEFT JOIN relay.suppressions s
    ON (s.target_digest = a.digest OR s.target_digest_next = a.digest)
    AND ((a.kind = 'email' AND s.channel = 'email')
      OR (a.kind = 'phone' AND s.channel IN ('sms', 'voice', 'whatsapp')))
  LEFT JOIN relay.import_records b
    ON b.entity_kind = 'suppression' AND b.entity_key = s.id::text
    AND b.import_id IN (SELECT i.id FROM relay.imports i
      WHERE i.batch = $4 AND i.kind = 'suppressions')
  """

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @doc "Queues a job inside the current transaction; rolls the transaction back when it is not queued."
  @spec insert_job!(Ecto.Changeset.t()) :: :ok
  def insert_job!(changeset) do
    case Oban.insert(changeset) do
      {:ok, _job} -> :ok
      {:error, reason} -> Repo.rollback({:job_not_queued, reason})
    end
  end

  # OP-96
  # OP-55 (2)
  @doc "Records an import request with its sealed content; `:order_violation` when a subscribers, devices or scheduled import comes before the suppressions and consents of its batch completed."
  @spec request(map(), <<_::256>>, Actor.t()) :: :requested | :order_violation
  def request(r, digest, %Actor{} = actor) do
    params =
      [
        r.id,
        r.kind,
        r.batch,
        r.line_count,
        r.byte_size,
        r.content_sha256,
        r.content_ct,
        r.content_key_id,
        r.requested_by,
        digest
      ] ++ Actor.params(actor)

    [row] = Repo.call!("relay_fn.import_request", params)
    Repo.code!(row["import_request"], [:requested, :order_violation])
  end

  # OP-55 (6)
  @doc "Records what lines of a pending import wrote: `{line, entity_kind, entity_key, recipient_id, provider_ref_ct, source_last_seen_at}` each; a line recorded before is kept."
  @spec record(Relay.Id.t(), [tuple()]) :: :recorded | :not_pending | :not_found
  def record(id, records) do
    columns = records |> Enum.map(&Tuple.to_list/1) |> transpose(6)
    [row] = Repo.call!("relay_fn.import_record", [id | columns])
    Repo.code!(row["import_record"], [:recorded, :not_pending, :not_found])
  end

  defp transpose([], width), do: List.duplicate([], width)
  defp transpose(rows, _width), do: rows |> Enum.zip() |> Enum.map(&Tuple.to_list/1)

  # OP-96
  @doc "Completes a pending import with its report and clears its content."
  @spec complete(Relay.Id.t(), map()) :: :completed | :not_pending | :not_found
  def complete(id, report) do
    [row] = Repo.call!("relay_fn.import_complete", [id, report])
    Repo.code!(row["import_complete"], [:completed, :not_pending, :not_found])
  end

  # OP-96
  @doc "Fails a pending import as `unavailable` or `content_unreadable` and clears its content."
  @spec fail(Relay.Id.t(), String.t()) :: :failed | :not_pending | :not_found
  def fail(id, failure) do
    [row] = Repo.call!("relay_fn.import_fail", [id, failure])
    Repo.code!(row["import_fail"], [:failed, :not_pending, :not_found])
  end

  @doc "Reads an import of the established scope, or `nil`."
  @spec get(Relay.Id.t()) :: map() | nil
  def get(id) do
    sql = "SELECT #{@columns} FROM relay.imports i WHERE i.id = $1"

    case maps(Repo.scoped_query!(sql, [id])) do
      [row] -> row
      [] -> nil
    end
  end

  # OP-55 (2)
  @doc "Counts the imported addresses `{number, kind, digest}` (`kind` `email` or `phone`, every readable digest of an address under the same number) that are suppressed now, that the suppressions imports of `batch` name, and of those how many are still suppressed."
  @spec suppression_counts([{non_neg_integer(), String.t(), binary()}], String.t()) :: %{
          suppressed: non_neg_integer(),
          expected: non_neg_integer(),
          expected_suppressed: non_neg_integer()
        }
  def suppression_counts(addresses, batch) do
    numbers = Enum.map(addresses, &elem(&1, 0))
    kinds = Enum.map(addresses, &elem(&1, 1))
    digests = Enum.map(addresses, &elem(&1, 2))
    [row] = maps(Repo.scoped_query!(@suppressed, [numbers, kinds, digests, batch]))

    %{
      suppressed: row["suppressed"],
      expected: row["expected"],
      expected_suppressed: row["expected_suppressed"]
    }
  end

  defp maps(%Postgrex.Result{columns: columns, rows: rows}),
    do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
end
