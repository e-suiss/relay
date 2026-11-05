defmodule Relay.Channels.Whatsapp.Store do
  @moduledoc """
  Data access of the WhatsApp templates (CH-57, TP-23) and the WhatsApp tenant events: the write paths `relay_fn.whatsapp_template_register`, `relay_fn.whatsapp_template_status`, `relay_fn.whatsapp_template_category` and `relay_fn.whatsapp_template_edit`, the template reads and `relay_fn.outbox_append`. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Repo

  @select """
  SELECT t.id, t.provider_account_id, t.waba_id, t.name, t.language, t.message_class,
    t.category, t.meta_category, t.status, t.meta_status, t.meta_template_id,
    t.rejection_reason, t.quality, t.components, t.approved_components, t.edits,
    t.status_changed_at, t.version, t.created_at, t.updated_at
  FROM relay.whatsapp_templates t
  """

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # CH-57
  @doc "Registers a template; the same name and language with other content is `:content_conflict`."
  @spec register(map()) ::
          {:created | :exists | :content_conflict | :account_not_found, Relay.Id.t() | nil}
  def register(t) do
    [row] =
      Repo.call!("relay_fn.whatsapp_template_register", [
        t.id,
        t.provider_account_id,
        t.waba_id,
        t.name,
        t.language,
        t.message_class,
        t.category,
        t.components,
        t.content_digest
      ])

    {Repo.code!(row["result"], [:created, :exists, :content_conflict, :account_not_found]),
     row["template_id"]}
  end

  # TP-23
  @doc "Records a Meta status of a template as the Relay state `status`, under the version it was read at."
  @spec status(map()) :: {atom(), Relay.Id.t() | nil, String.t() | nil}
  def status(s) do
    [row] =
      Repo.call!("relay_fn.whatsapp_template_status", [
        s.provider_account_id,
        s.name,
        s.language,
        s.meta_template_id,
        s.meta_status,
        s.status,
        s.reason,
        s.expected_version
      ])

    {Repo.code!(row["result"], [:changed, :recorded, :unchanged, :version_conflict, :not_found]),
     row["template_id"], row["previous_status"]}
  end

  # CH-57
  @doc "Records the category Meta set for a template; a category other than the Relay class's is `:drifted`."
  @spec category(Relay.Id.t(), String.t(), String.t(), String.t()) ::
          {:drifted | :aligned | :unchanged | :not_found, Relay.Id.t() | nil}
  def category(provider_account_id, name, language, meta_category) do
    [row] =
      Repo.call!("relay_fn.whatsapp_template_category", [
        provider_account_id,
        name,
        language,
        meta_category
      ])

    {Repo.code!(row["result"], [:drifted, :aligned, :unchanged, :not_found]), row["template_id"]}
  end

  # TP-23
  @doc "Records an edit Meta made to a template at `edited_at`, with its new components when known."
  @spec edit(Relay.Id.t(), String.t(), String.t(), [map()] | nil, DateTime.t()) ::
          {:recorded | :unchanged | :not_found, Relay.Id.t() | nil}
  def edit(provider_account_id, name, language, components, edited_at) do
    [row] =
      Repo.call!("relay_fn.whatsapp_template_edit", [
        provider_account_id,
        name,
        language,
        components,
        edited_at
      ])

    {Repo.code!(row["result"], [:recorded, :unchanged, :not_found]), row["template_id"]}
  end

  # CH-57
  @doc "Reads a template, or `nil`."
  @spec get(Relay.Id.t()) :: map() | nil
  def get(id) do
    case rows(@select <> " WHERE t.id = $1", [id]) do
      [row] -> row
      [] -> nil
    end
  end

  # CH-57
  @doc "Reads the template of an account by Meta name and language, or `nil`."
  @spec find(Relay.Id.t(), String.t(), String.t()) :: map() | nil
  def find(provider_account_id, name, language) do
    sql =
      @select <> " WHERE t.provider_account_id = $1 AND t.name = $2 AND t.language = $3"

    case rows(sql, [provider_account_id, name, language]) do
      [row] -> row
      [] -> nil
    end
  end

  # API-56
  @doc "Lists templates newest first from a decoded cursor (`direction`, `sort_ts_us`, `id`); at most `limit + 1` rows come back, in newest-first order."
  @spec list(map() | nil, pos_integer()) :: [map()]
  def list(nil, limit),
    do: rows(@select <> " ORDER BY t.created_at DESC, t.id DESC LIMIT $1", [limit + 1])

  def list(%{direction: :after, sort_ts_us: ts, id: id}, limit) do
    rows(
      @select <>
        " WHERE (t.created_at, t.id) < ($1, $2) ORDER BY t.created_at DESC, t.id DESC LIMIT $3",
      [DateTime.from_unix!(ts, :microsecond), id, limit + 1]
    )
  end

  def list(%{direction: :before, sort_ts_us: ts, id: id}, limit) do
    sql = @select <> " WHERE (t.created_at, t.id) > ($1, $2) ORDER BY t.created_at, t.id LIMIT $3"

    sql
    |> rows([DateTime.from_unix!(ts, :microsecond), id, limit + 1])
    |> Enum.reverse()
  end

  # CH-57
  # CH-61
  @doc "Appends a WhatsApp tenant event to the outbox."
  @spec event(String.t(), String.t(), map()) :: :appended
  def event(type, stream_key, data) do
    params = [Relay.Id.generate(), type, stream_key, data, nil]
    [row] = Repo.call!("relay_fn.outbox_append", params)
    Repo.code!(row["result"], [:appended])
  end

  defp rows(sql, params) do
    %Postgrex.Result{columns: columns, rows: rows} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
