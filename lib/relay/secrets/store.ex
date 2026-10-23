defmodule Relay.Secrets.Store do
  @moduledoc false

  alias Relay.Repo
  alias Relay.Secrets.Ref

  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @spec register(map(), <<_::256>>, Relay.Actor.t()) :: {:ok, :created | :exists}
  def register(attrs, fingerprint, actor) do
    [row] =
      Repo.call!(
        "relay_fn.secret_ref_register",
        [
          attrs.id,
          Atom.to_string(attrs.kind),
          attrs.ref,
          nil,
          nil,
          attrs.ref_version,
          fingerprint,
          attrs.record_digest
        ] ++ Relay.Actor.params(actor)
      )

    {:ok, Repo.code!(row["secret_ref_register"], [:created, :exists])}
  end

  @spec get(Relay.Id.t()) :: {:ok, {Ref.t(), String.t() | nil}} | {:error, Relay.Error.t()}
  def get(id) do
    """
    SELECT tenant_id, environment::text AS environment, id, kind, ref, ref_version, fingerprint,
      state, created_at, retired_at
    FROM relay.secret_refs
    WHERE id = $1
    """
    |> Repo.scoped_query!([id])
    |> case do
      %{rows: [row], columns: columns} -> {:ok, ref(Map.new(Enum.zip(columns, row)))}
      _ -> {:error, Relay.Error.new(:not_found, "secret reference not found")}
    end
  end

  @spec rotate(Relay.Id.t(), map(), <<_::256>>, binary(), Relay.Actor.t()) ::
          {:ok, :rotated} | {:error, Relay.Error.t()}
  def rotate(retire_id, new, fingerprint, retire_digest, actor) do
    with {:ok, :created} <- register(new, fingerprint, actor),
         [%{"secret_ref_retire" => "retired"}] <-
           Repo.call!(
             "relay_fn.secret_ref_retire",
             [retire_id, retire_digest] ++ Relay.Actor.params(actor)
           ) do
      {:ok, :rotated}
    else
      _ -> Repo.rollback(Relay.Error.new(:rotation_refused, "secret rotation refused"))
    end
  end

  defp ref(row) do
    {%Ref{
       id: row["id"],
       kind: kind(row["kind"]),
       ref_version: row["ref_version"],
       fingerprint: row["fingerprint"],
       state: if(row["state"] == "active", do: :active, else: :retired),
       created_at: row["created_at"],
       retired_at: row["retired_at"]
     }, row["ref"]}
  end

  defp kind("provider_credential"), do: :provider_credential
  defp kind("channel_identity"), do: :channel_identity
  defp kind("webhook_signing"), do: :webhook_signing
end
