defmodule Relay.Tenancy.KillSwitch.Store do
  @moduledoc """
  Data access for kill switches and for the deliveries they pause. Writes call the `relay_fn` functions inside `Relay.Repo.in_scope/3`; the full snapshot and the scopes a platform record touches are read through the `relay_ops` escape hatches `:kill_switch_snapshot` and `:kill_switch_scopes`, which return no content beyond the records themselves and tenant identifiers.
  """

  alias Relay.Actor
  alias Relay.Repo
  alias Relay.Tenancy.KillSwitch.Record

  @columns ~w(tenant_id environment id scope_kind scope_ref channel target_kind target_ref
              message_class security_approval_ref state canary_percent reason ticket_ref origin
              created_by_ref expires_at no_ttl_approval_ref supersedes_id status released_at
              released_by_ref release_reason release_approval_ref created_at)

  @type digest :: <<_::256>>

  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @doc "Returns the scope of the current scoped transaction; raises outside one."
  @spec current_scope!() :: Relay.Scope.t()
  def current_scope! do
    case Repo.current_scope() do
      %Relay.Scope{} = scope -> scope
      nil -> raise Relay.ScopeError, :missing
    end
  end

  @doc "Reads the installation tenant's identifier."
  @spec installation_tenant_id() :: Relay.Id.t()
  def installation_tenant_id do
    {:ok, %Postgrex.Result{rows: [[id]]}} =
      Repo.unscoped_query(
        :installation_lookup,
        "SELECT installation_tenant_id FROM relay.installation",
        []
      )

    id
  end

  # TN-39
  @doc "Reads the generation and every kill switch record in force, across tenants."
  @spec snapshot() :: {:ok, non_neg_integer(), [Record.t()]} | {:error, Relay.Error.t()}
  def snapshot do
    case Repo.unscoped_query(
           :kill_switch_snapshot,
           "SELECT * FROM relay_ops.kill_switch_snapshot()",
           []
         ) do
      {:ok, %Postgrex.Result{columns: columns, rows: [_ | _] = rows}} ->
        maps = Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
        generation = hd(maps)["generation"]
        {:ok, generation, for(%{"id" => <<_::128>>} = row <- maps, do: Record.from_row(row))}

      {:ok, _} ->
        {:error, Relay.Error.new(:kill_switch_state_missing, "kill switch generation is missing")}

      {:error, error} ->
        {:error,
         Relay.Error.new(:kill_switch_unreadable, "kill switch state could not be read", %{
           error: Exception.message(error)
         })}
    end
  end

  @doc "Lists the scopes a kill switch's sweep, bulk cancel or the paused expiry has to visit (`nil`: every scope with paused deliveries)."
  @spec scopes(Relay.Id.t() | nil) :: [Relay.Scope.t()]
  def scopes(kill_switch_id) do
    for row <-
          Repo.call_unscoped!(:kill_switch_scopes, "relay_ops.kill_switch_scopes", [
            kill_switch_id
          ]),
        do: Relay.Scope.new!(row["tenant_id"], env(row["environment"]))
  end

  # TN-36
  # TN-41
  @doc "Engages a kill switch in the established scope."
  @spec engage(map(), digest(), Actor.t()) :: {atom(), Relay.Id.t() | nil, integer() | nil}
  def engage(attrs, digest, %Actor{} = actor) do
    infinite? = attrs.paused_until == :infinity
    paused_until = if infinite?, do: nil, else: attrs.paused_until

    params =
      [
        attrs.id,
        Atom.to_string(attrs.scope_kind),
        attrs.scope_ref,
        attrs.channel,
        Atom.to_string(attrs.target_kind),
        attrs.target_ref,
        attrs.message_class,
        attrs.security_approval_ref,
        Atom.to_string(attrs.state),
        attrs.canary_percent,
        paused_until,
        attrs.reason,
        attrs.ticket_ref,
        attrs.expires_at,
        attrs.no_ttl_approval_ref,
        Atom.to_string(attrs.origin),
        digest
      ] ++ Actor.params(actor) ++ [infinite?]

    sql = """
    SELECT * FROM relay_fn.kill_switch_engage($1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
      CASE WHEN $22::boolean THEN 'infinity'::timestamptz ELSE $11::timestamptz END,
      $12, $13, $14, $15, $16, $17, $18, $19, $20, $21)
    """

    %Postgrex.Result{rows: [[result, id, generation]]} = Repo.scoped_query!(sql, params)

    {Repo.code!(result, [
       :engaged,
       :exists,
       :reason_required,
       :ttl_required,
       :security_approval_required,
       :invalid_scope,
       :scope_not_found,
       :dead_man_active
     ]), id, generation}
  end

  # TN-22
  # TN-70 (1)
  @doc "Releases a kill switch in the established scope."
  @spec release(Relay.Id.t(), String.t(), String.t() | nil, digest(), Actor.t()) ::
          {atom(), integer() | nil}
  def release(id, reason, approval, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.kill_switch_release",
        [id, reason, approval, digest] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [
       :released,
       :already_released,
       :not_found,
       :approval_required,
       :reason_required
     ]), row["generation"]}
  end

  # TN-22
  @doc "Replaces a kill switch by a new record of the same dimensions in the established scope."
  @spec replace(Relay.Id.t(), map(), digest(), Actor.t()) ::
          {atom(), Relay.Id.t() | nil, integer() | nil}
  def replace(old_id, attrs, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.kill_switch_replace",
        [
          old_id,
          attrs.id,
          Atom.to_string(attrs.state),
          attrs.canary_percent,
          attrs.paused_until,
          attrs.reason,
          attrs.expires_at,
          attrs.no_ttl_approval_ref,
          attrs.release_approval_ref,
          digest
        ] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [
       :replaced,
       :not_found,
       :already_released,
       :approval_required,
       :reason_required,
       :ttl_required
     ]), row["kill_switch_id"], row["generation"]}
  end

  # TN-41
  @doc "Lists the established scope's kill switches together with the platform records that apply to it."
  @spec list(boolean(), Relay.Id.t() | nil, pos_integer()) :: [Record.t()]
  def list(include_released, after_id, limit) do
    columns = Enum.join(@columns, ", ")

    %Postgrex.Result{columns: names, rows: rows} =
      Repo.scoped_query!(
        "SELECT #{columns}, nullif(paused_until, 'infinity'::timestamptz) AS paused_until FROM relay_fn.kill_switch_list($1, $2, $3)",
        [include_released, after_id, limit],
        shared: :installation
      )

    for row <- rows, do: names |> Enum.zip(row) |> Map.new() |> Record.from_row()
  end

  # T-15 (5)
  @doc "Reads the first-step state of a delivery: `sendable`, `cancelled`, `paused`, `expired`, `terminal`, `deferred` or `not_found`, with the fields the kill switch evaluation needs."
  @spec gate(Relay.Id.t()) :: map()
  def gate(delivery_id) do
    [row] = Repo.call!("relay_fn.delivery_gate", [delivery_id])

    Map.put(
      row,
      "result",
      Repo.code!(row["result"], [
        :sendable,
        :cancelled,
        :paused,
        :expired,
        :terminal,
        :deferred,
        :not_found
      ])
    )
  end

  # TN-40
  @doc "Marks a delivery `PAUSED` by a kill switch."
  @spec pause(Relay.Id.t(), String.t(), Relay.Id.t()) :: atom()
  def pause(delivery_id, rule_id, kill_switch_id) do
    [row] = Repo.call!("relay_fn.delivery_pause", [delivery_id, rule_id, kill_switch_id])
    Repo.code!(row["delivery_pause"], [:paused, :already_paused, :already_terminal, :not_found])
  end

  # TN-40
  @doc "Lifts the `PAUSED` mark of a delivery after the policy lattice decided to send it."
  @spec resume(Relay.Id.t(), String.t(), String.t()) :: atom()
  def resume(delivery_id, decision_ref, rule_id) do
    [row] = Repo.call!("relay_fn.delivery_resume", [delivery_id, decision_ref, rule_id])
    Repo.code!(row["delivery_resume"], [:resumed, :not_paused, :already_terminal, :not_found])
  end

  # TN-40
  @doc "Cancels one delivery with a rule identifier."
  @spec cancel(Relay.Id.t(), String.t(), digest(), Actor.t()) :: atom()
  def cancel(delivery_id, rule_id, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.delivery_cancel",
        [delivery_id, rule_id, digest] ++ Actor.params(actor)
      )

    Repo.code!(row["delivery_cancel"], [:cancelled, :already_terminal, :not_found])
  end

  # TN-40
  @doc "Closes a delivery whose message expired as `expired`."
  @spec expire(Relay.Id.t(), String.t()) :: atom()
  def expire(delivery_id, rule_id) do
    [row] = Repo.call!("relay_fn.delivery_expire", [delivery_id, rule_id])
    Repo.code!(row["delivery_expire"], [:expired, :already_terminal, :not_found])
  end

  # TN-40
  @doc "Marks one batch of the established scope's pending deliveries that a kill switch matches as `PAUSED`."
  @spec pause_matching(Relay.Id.t(), pos_integer()) :: {non_neg_integer(), boolean()}
  def pause_matching(kill_switch_id, limit) do
    [row] = Repo.call!("relay_fn.deliveries_pause_matching", [kill_switch_id, limit])
    {row["paused"], row["has_more"]}
  end

  # TN-47
  @doc "Cancels one batch of the deliveries a kill switch paused in the established scope."
  @spec cancel_paused(Relay.Id.t(), String.t(), pos_integer()) :: {non_neg_integer(), boolean()}
  def cancel_paused(kill_switch_id, rule_id, limit) do
    [row] = Repo.call!("relay_fn.paused_deliveries_cancel", [kill_switch_id, rule_id, limit])
    {row["cancelled"], row["has_more"]}
  end

  # TN-40
  @doc "Closes one batch of the established scope's paused deliveries whose message expired."
  @spec expire_paused(pos_integer()) :: non_neg_integer()
  def expire_paused(limit) do
    [row] = Repo.call!("relay_fn.paused_deliveries_expire", [limit])
    row["paused_deliveries_expire"]
  end

  @doc "Reads the identifiers of the deliveries a kill switch paused in the established scope, oldest first."
  @spec paused(Relay.Id.t(), pos_integer()) :: [Relay.Id.t()]
  def paused(kill_switch_id, limit) do
    %Postgrex.Result{rows: rows} =
      Repo.scoped_query!(
        """
        SELECT id FROM relay.deliveries
        WHERE pause_kill_switch_id = $1 AND paused_at IS NOT NULL AND failure_kind IS NULL
          AND delivery_rank = 0
        ORDER BY created_at, id
        LIMIT $2
        """,
        [kill_switch_id, limit]
      )

    Enum.map(rows, &hd/1)
  end

  # TN-47
  @doc "Appends an audit record in the established scope."
  @spec audit(Relay.Id.t(), String.t(), String.t(), String.t(), String.t(), digest(), Actor.t()) ::
          :appended
  def audit(id, action, target_type, target_id, reason, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.audit_append",
        [id, action] ++ Actor.params(actor) ++ [target_type, target_id, reason, nil, nil, digest]
      )

    Repo.code!(row["audit_append"], [:appended])
  end

  @doc "Inserts a job in the current transaction."
  @spec insert_job(Ecto.Changeset.t()) :: Oban.Job.t()
  def insert_job(changeset), do: Oban.insert!(changeset)

  defp env(text) do
    {:ok, environment} = Relay.Environment.cast(text)
    environment
  end
end
