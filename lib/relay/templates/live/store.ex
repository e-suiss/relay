defmodule Relay.Templates.Live.Store do
  @moduledoc """
  Data access of the running render path (TP-50): the channel and locale index of pinned template versions at acceptance, and at send time the delivery's render input (its notification, event payload, event schema and recipient time zone), the pinned template and layout versions, the tenant's locale and time zone defaults and the registration of a recipient's content key. Every function except `in_scope/2` runs inside the caller's `Relay.Repo.in_scope/3`.
  """

  alias Relay.Repo

  @defaults ["default_locale", "default_timezone"]

  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # TP-11
  # TP-26
  @doc "The locales of every channel of template versions, by version identifier: each row carries its `layout_key` and its `locales`, a map of channel to cell locales; no cell content is read."
  @spec cell_index([Relay.Id.t()]) :: %{Relay.Id.t() => map()}
  def cell_index([]), do: %{}

  def cell_index(version_ids) do
    """
    SELECT v.id, v.layout_key,
      COALESCE((SELECT jsonb_object_agg(c.key, COALESCE((SELECT jsonb_agg(l.key ORDER BY l.key)
          FROM jsonb_each(c.value) l), '[]'::jsonb))
        FROM jsonb_each(v.cells) c), '{}'::jsonb) AS locales
    FROM relay.template_versions v WHERE v.id = ANY ($1)
    """
    |> Repo.scoped_query!([version_ids])
    |> maps()
    |> Map.new(&{&1["id"], &1})
  end

  # TP-25
  @doc "The tenant's `default_locale` and `default_timezone` for a sub-tenant (`nil` for the tenant level), with sub-tenant inheritance."
  @spec defaults(Relay.Id.t() | nil) :: %{String.t() => term()}
  def defaults(subtenant_id) do
    for row <- Repo.call!("relay_fn.setting_resolve", [subtenant_id, @defaults]),
        row["value"] != nil,
        into: %{},
        do: {row["key"], row["value"]}
  end

  # TP-50
  @doc "The render input of a delivery: its channel and state, the notification's recipient, sub-tenant, class and subtype, the event schema of the workflow version, the recipient's time zone and the sealed event data; `nil` when there is no such delivery."
  @spec delivery(Relay.Id.t()) :: map() | nil
  def delivery(delivery_id) do
    one(
      """
      SELECT d.id, d.channel::text AS channel, d.failure_kind::text AS failure_kind,
        n.id AS notification_id, n.recipient_id, n.subtenant_id,
        n.message_class::text AS message_class, n.security_subtype::text AS security_subtype,
        v.event_schema, r.timezone, p.data_ct, p.key_id AS data_key_id,
        p.erased_at AS data_erased_at
      FROM relay.deliveries d
      JOIN relay.notifications n ON n.tenant_id = d.tenant_id AND n.environment = d.environment
        AND n.id = d.notification_id
      LEFT JOIN relay.workflow_versions v ON v.tenant_id = n.tenant_id
        AND v.environment = n.environment AND v.id = n.workflow_version_id
      LEFT JOIN relay.recipients r ON r.tenant_id = n.tenant_id AND r.environment = n.environment
        AND r.id = n.recipient_id
      LEFT JOIN relay.events e ON e.tenant_id = n.tenant_id AND e.environment = n.environment
        AND e.id = n.event_id
      LEFT JOIN relay.event_payloads p ON p.tenant_id = e.tenant_id
        AND p.environment = e.environment AND p.event_id = e.id
        AND p.created_at = e.payload_created_at
      WHERE d.id = $1
      """,
      [delivery_id]
    )
  end

  # TP-48
  # INV-48
  @doc "A template version by identifier with its template's key and owner, or `nil`."
  @spec template_version(Relay.Id.t()) :: map() | nil
  def template_version(version_id) do
    one(
      """
      SELECT v.id, v.version_no, v.cells, v.default_locale, v.sensitivity, v.sms_encoding,
        v.transliterate, v.allow_raw, v.layout_key, t.key, t.owner
      FROM relay.template_versions v
      JOIN relay.templates t ON t.tenant_id = v.tenant_id AND t.environment = v.environment
        AND t.id = v.template_id
      WHERE v.id = $1
      """,
      [version_id]
    )
  end

  # TP-35
  @doc "The content of a layout version by identifier, or `nil`."
  @spec layout_content(Relay.Id.t()) :: map() | nil
  def layout_content(version_id) do
    case one("SELECT v.content FROM relay.layout_versions v WHERE v.id = $1", [version_id]) do
      %{"content" => content} -> content
      nil -> nil
    end
  end

  # TP-40
  # OP-18
  @doc "Registers a recipient's subject key of a retention class; an active key of that class is returned instead (`:exists`)."
  @spec subject_key_create(Relay.Id.t(), Relay.Id.t(), String.t(), binary(), Relay.Id.t()) ::
          {atom(), Relay.Id.t() | nil}
  def subject_key_create(id, recipient_id, retention_class, wrapped_dek, wrapping_key_id) do
    [row] =
      Repo.call!("relay_fn.subject_key_create", [
        id,
        recipient_id,
        retention_class,
        wrapped_dek,
        wrapping_key_id
      ])

    {Repo.code!(row["result"], [:created, :exists, :recipient_not_found, :recipient_deleted]),
     row["subject_key_id"]}
  end

  defp one(sql, params) do
    case maps(Repo.scoped_query!(sql, params)) do
      [row] -> row
      [] -> nil
    end
  end

  defp maps(%Postgrex.Result{columns: columns, rows: rows}),
    do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
end
