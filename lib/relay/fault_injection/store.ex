defmodule Relay.FaultInjection.Store do
  @moduledoc """
  Data access for fault injections (OP-92). The records live in the installation scope; every write calls a `relay_fn.fault_injection_*` function inside `Relay.Repo.in_scope/3`, which writes the record and its audit record in one transaction.
  """

  alias Relay.Actor
  alias Relay.FaultInjection.Record
  alias Relay.Repo

  @doc "The installation scope the records live in."
  @spec installation_scope() :: Relay.Scope.t()
  def installation_scope do
    {:ok, %Postgrex.Result{rows: [[id]]}} =
      Repo.unscoped_query(
        :installation_lookup,
        "SELECT installation_tenant_id FROM relay.installation",
        []
      )

    Relay.Scope.new!(id, :live)
  end

  # OP-92
  # OP-44
  @doc "Writes a fault injection in the installation scope; an active record of the same dimensions answers `:exists` with its identifier."
  @spec engage(map(), <<_::256>>, Actor.t()) ::
          {:ok, {atom(), Relay.Id.t() | nil}} | {:error, term()}
  def engage(attrs, digest, %Actor{} = actor) do
    params =
      [
        attrs.id,
        Atom.to_string(attrs.scope_kind),
        attrs.scope_tenant_id,
        Relay.Environment.dump(attrs.target_environment),
        attrs.channel,
        attrs.provider,
        Atom.to_string(attrs.kind),
        attrs.rate_percent,
        attrs.delay_ms,
        attrs.reason,
        attrs.ttl_seconds,
        digest
      ] ++ Actor.params(actor)

    Repo.in_scope(installation_scope(), fn _status ->
      [row] = Repo.call!("relay_fn.fault_injection_engage", params)

      {Repo.code!(row["result"], [:engaged, :exists, :reason_required, :invalid_scope]),
       row["fault_injection_id"]}
    end)
  end

  # OP-92
  # OP-44
  @doc "Clears a fault injection in the installation scope."
  @spec clear(Relay.Id.t(), String.t() | nil, <<_::256>>, Actor.t()) ::
          {:ok, atom()} | {:error, term()}
  def clear(id, reason, digest, %Actor{} = actor) do
    Repo.in_scope(installation_scope(), fn _status ->
      [row] =
        Repo.call!("relay_fn.fault_injection_clear", [id, reason, digest] ++ Actor.params(actor))

      Repo.code!(row["fault_injection_clear"], [
        :cleared,
        :already_cleared,
        :not_found,
        :reason_required
      ])
    end)
  end

  # OP-92
  @doc "Lists the records, newest first: those in force, or with `include_inactive` also the cleared and expired ones."
  @spec list(boolean(), pos_integer()) :: {:ok, [Record.t()]} | {:error, term()}
  def list(include_inactive, limit) do
    Repo.in_scope(installation_scope(), fn _status ->
      for row <- Repo.call!("relay_fn.fault_injection_list", [include_inactive, limit]),
          do: Record.from_row(row)
    end)
  end
end
