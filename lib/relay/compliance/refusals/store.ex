defmodule Relay.Compliance.Refusals.Store do
  @moduledoc """
  Data access of refusals and unsubscribe links. Writes call `relay_fn.refusal_apply` and `relay_fn.unsubscribe_token_revoke`; reads select the rows of the established scope.
  """

  alias Relay.Compliance.Refusal
  alias Relay.Repo

  @link """
  SELECT r.locale, r.legal_type, c.message_class::text AS message_class,
    (SELECT p.value FROM relay.preferences p
      WHERE p.recipient_id = r.id AND p.level = 'category_channel' AND p.key = $2
        AND p.channel = $3) AS preference,
    EXISTS (SELECT 1 FROM relay.unsubscribe_token_revocations v WHERE v.id = $4) AS revoked
  FROM relay.recipients r
  LEFT JOIN relay.categories c ON c.tenant_id = r.tenant_id AND c.environment = r.environment
    AND c.key = $2
  WHERE r.id = $1 AND r.state = 'active'
  """

  @refusal """
  SELECT f.id, f.recipient_id, f.brand_subtenant_id, f.channel::text AS channel, f.source,
    f.scope, f.occurred_at, r.legal_type
  FROM relay.refusals f
  JOIN relay.recipients r ON r.tenant_id = f.tenant_id AND r.environment = f.environment
    AND r.id = f.recipient_id
  WHERE f.id = $1
  """

  @address """
  SELECT a.address_ct FROM relay.recipient_addresses a
  WHERE a.recipient_id = $1 AND a.kind = $2 AND a.state = 'active'
  """

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # PC-38
  # PC-39
  # INV-18
  @doc "Applies a refusal; see `relay_fn.refusal_apply`. `sealed` carries the refusal's `:evidence_ct` and `:evidence_key_id` and the consent copy's `:consent_ct`."
  @spec apply_refusal(Relay.Id.t(), Refusal.t(), map()) :: {atom(), Relay.Id.t() | nil}
  def apply_refusal(id, refusal, sealed) do
    [row] =
      Repo.call!("relay_fn.refusal_apply", [
        id,
        refusal.recipient_id,
        refusal.brand_subtenant_id,
        refusal.channel,
        refusal.source,
        refusal.scope,
        refusal.category,
        refusal.ref,
        refusal.occurred_at,
        sealed.evidence_ct,
        sealed.evidence_key_id,
        sealed.consent_ct,
        refusal.provider_account_id,
        refusal.actor_ref
      ])

    {Repo.code!(row["result"], [
       :applied,
       :reapplied,
       :exists,
       :recipient_not_found,
       :subtenant_not_found,
       :evidence_key_invalid,
       :category_not_found,
       :not_allowed
     ]), row["refusal_id"]}
  end

  # T-15
  @doc "Queues a job inside the current transaction; rolls the transaction back when it is not queued."
  @spec insert_job!(Ecto.Changeset.t()) :: :ok
  def insert_job!(changeset) do
    case Oban.insert(changeset) do
      {:ok, _job} -> :ok
      {:error, reason} -> Repo.rollback({:job_not_queued, reason})
    end
  end

  # PC-35
  # PC-36
  @doc "What an unsubscribe link of a recipient, category and channel leads to: the recipient's locale and legal type, the category's class, the recipient's preference of the category on the channel and whether the token is revoked; `nil` when the recipient is not active."
  @spec link(Relay.Id.t(), String.t(), String.t(), Relay.Id.t()) :: map() | nil
  def link(recipient_id, category, channel, token_id),
    do: one(@link, [recipient_id, category, channel, token_id])

  # PC-59 (1)
  # PC-21
  @doc "The current consent states of a recipient per brand and channel."
  @spec consents(Relay.Id.t()) :: [map()]
  def consents(recipient_id), do: Repo.call!("relay_fn.consent_current", [recipient_id])

  # PC-35
  @doc "Puts a token on the revocation list."
  @spec revoke(Relay.Id.t(), String.t(), String.t()) :: :revoked | :already_revoked
  def revoke(token_id, reason, actor_ref) do
    [row] = Repo.call!("relay_fn.unsubscribe_token_revoke", [token_id, reason, actor_ref])
    Repo.code!(row["unsubscribe_token_revoke"], [:revoked, :already_revoked])
  end

  # PC-38
  @doc "An applied refusal with its recipient's legal type; `nil` when there is none."
  @spec refusal(Relay.Id.t()) :: map() | nil
  def refusal(id), do: one(@refusal, [id])

  @doc "The sealed active address of a recipient of `kind` (`email` or `phone`); `nil` when it has none."
  @spec address(Relay.Id.t(), String.t()) :: binary() | nil
  def address(recipient_id, kind) do
    case one(@address, [recipient_id, kind]) do
      %{"address_ct" => ct} -> ct
      nil -> nil
    end
  end

  defp one(sql, params) do
    case maps(Repo.scoped_query!(sql, params)) do
      [row | _rest] -> row
      [] -> nil
    end
  end

  defp maps(%Postgrex.Result{columns: columns, rows: rows}),
    do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
end
