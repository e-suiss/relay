defmodule Relay.Channels.Live.Store do
  @moduledoc """
  Data access of the channel step of the delivery job: the delivery with its notification and event, the send mode settings, and the recipient's active address. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Repo

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # T-15
  @doc "Reads what the channel step needs of a delivery: its channel, target kind, recipient, class, `expires_at`, test flag and the requested send mode of its event; `nil` when there is no such delivery."
  @spec delivery(Relay.Id.t()) :: map() | nil
  def delivery(delivery_id) do
    one(
      """
      SELECT d.tenant_id, d.environment, d.id, d.channel::text AS channel, d.target_kind,
        d.recipient_id, d.provider, d.provider_account_id, d.traceparent,
        n.message_class::text AS message_class, n.expires_at, n.is_test, e.send_mode::text AS send_mode
      FROM relay.deliveries d
      JOIN relay.notifications n ON n.tenant_id = d.tenant_id AND n.environment = d.environment
        AND n.id = d.notification_id
      LEFT JOIN relay.events e ON e.tenant_id = n.tenant_id AND e.environment = n.environment
        AND e.id = n.event_id
      WHERE d.id = $1
      """,
      [delivery_id]
    )
  end

  # API-62
  # OP-51
  @doc "Reads the tenant-level settings among `keys` as a map of key to value."
  @spec settings([String.t()]) :: %{String.t() => term()}
  def settings(keys) do
    rows =
      all(
        "SELECT tenant_id, environment, key, value FROM relay.settings WHERE subtenant_id IS NULL AND key = ANY($1::text[])",
        [keys]
      )

    Map.new(rows, &{&1["key"], &1["value"]})
  end

  # CH-28
  @doc "Reads the active address of `kind` (`email` or `phone`) of a recipient: its identifier, ciphertext and key; `nil` when there is none."
  @spec address(Relay.Id.t(), String.t()) :: map() | nil
  def address(recipient_id, kind) do
    one(
      "SELECT tenant_id, environment, id, address_ct, address_key_id FROM relay.recipient_addresses WHERE recipient_id = $1 AND kind = $2 AND state = 'active'",
      [recipient_id, kind]
    )
  end

  defp one(sql, params), do: sql |> all(params) |> List.first()

  defp all(sql, params) do
    %Postgrex.Result{columns: columns, rows: rows} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
