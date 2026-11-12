defmodule Relay.TemplateStore do
  @moduledoc """
  Data access of templates, layouts, partials, the pinned render plan of a delivery and its render content snapshot (TP-48, TP-50). Writes call the `relay_fn.template_*`, `relay_fn.layout_*`, `relay_fn.partial_*` and `relay_fn.delivery_*` render functions; reads select the rows of the established scope. Every function except `in_scope/2` runs inside the caller's `Relay.Repo.in_scope/3`.

  * A resource is addressed by its key and level: `at` carries the `:key`, the `:subtenant_id` (`nil` for the tenant level) and, for a producer-owned template, the producer `:product`. A tenant writing a producer template, or a producer writing another owner's, gets `:protected`.
  * A published version never changes; writing opens or replaces the draft, publication records the gate findings and moves the live pointer, rollback moves the pointer back and creates no version. Identical content is never published twice (`:duplicate`).
  * A template keeps its message class and type after its first publication (INV-21).
  * The render plan is pinned when the delivery is created and never changes; the first successful render records its digest and measures and the content snapshot, sealed under the recipient's subject key or kept as a digest only for security subtypes and `retention: none` (TP-40). A render failure fails the delivery, appends the ledger event and the `notification.render_failed` event in one transaction (TP-41).
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Actor
  alias Relay.Repo

  @type digest :: <<_::256>>
  @type at :: %{
          required(:key) => String.t(),
          optional(:subtenant_id) => Relay.Id.t() | nil,
          optional(:product) => String.t() | nil
        }
  @type kind :: :layout | :partial
  @type gate :: %{
          required(:variables) => map(),
          required(:measures) => map(),
          required(:findings) => [map()],
          required(:accept_warnings) => boolean(),
          optional(:checksum) => digest() | nil,
          optional(:diff) => map() | nil
        }
  @type row :: %{String.t() => term()}
  @type version :: pos_integer() | nil
  @type maybe_id :: Relay.Id.t() | nil
  @type brand_field :: %{value: term(), source: String.t()}

  @lookup [:not_found, :archived, :protected, :version_conflict]
  @gate [:no_draft, :draft_changed, :gate_failed, :warnings_unaccepted, :duplicate]
  @template_create [
    :created,
    :key_conflict,
    :subtenant_not_found,
    :category_not_found,
    :category_archived,
    :layout_not_found,
    :partial_not_found,
    :tenant_inactive
  ]
  @template_update [:updated, :unchanged, :category_not_found, :category_archived, :class_locked]
  @template_draft [:created, :replaced, :unchanged, :layout_not_found, :partial_not_found]
  @template_publish [
    :published,
    :sensitivity_missing,
    :translation_unapproved,
    :layout_not_published,
    :partial_not_published
  ]
  @rollback [:rolled_back, :unchanged, :version_not_found, :version_archived]
  @archive [:archived, :already_archived, :not_found, :version_conflict]
  @asset_draft [:created, :replaced, :unchanged, :not_found, :archived, :version_conflict]
  @brand_fields ~w(contact footer legal_name logo_url mersis postal_address primary_color
                   secondary_color sender_name)

  @template_columns """
  t.tenant_id, t.environment::text AS environment, t.id, t.key, t.subtenant_id, t.owner,
  t.owner_product, t.name, c.key AS category, t.message_class::text AS message_class,
  t.template_type, t.state, t.archived_at, t.live_version_id, t.live_version_no,
  t.first_published_at, t.version, t.created_at, t.updated_at
  """

  @template_version_columns """
  v.tenant_id, v.environment::text AS environment, v.id, v.template_id, v.state, v.version_no,
  v.checksum, v.cells, v.default_locale, v.sensitivity, v.sensitivity_approval, v.sms_encoding,
  v.transliterate, v.allow_raw, v.layout_key, v.partial_keys, v.producer_brand, v.variables,
  v.measures, v.findings, v.warnings_accepted, v.warnings_accepted_by_ref, v.diff,
  v.previous_version_no, v.drafted_by_ref, v.published_at, v.published_by_ref, v.archived_at,
  v.created_at, v.updated_at
  """

  @asset_columns """
  a.tenant_id, a.environment::text AS environment, a.id, a.key, a.subtenant_id, a.owner, a.name,
  a.state, a.archived_at, a.live_version_id, a.live_version_no, a.version, a.created_at,
  a.updated_at
  """

  @asset_version_columns """
  v.tenant_id, v.environment::text AS environment, v.id, v.state, v.version_no, v.checksum,
  v.content, v.findings, v.warnings_accepted, v.warnings_accepted_by_ref, v.diff,
  v.previous_version_no, v.drafted_by_ref, v.published_at, v.published_by_ref, v.archived_at,
  v.created_at, v.updated_at
  """

  @asset_sql %{
    layout: %{
      get:
        "SELECT #{@asset_columns} FROM relay.layouts a WHERE a.key = $1 AND a.subtenant_id IS NOT DISTINCT FROM $2",
      page:
        "SELECT #{@asset_columns} FROM relay.layouts a WHERE a.subtenant_id IS NOT DISTINCT FROM $1 AND ($2::uuid IS NULL OR a.id > $2) ORDER BY a.id LIMIT $3",
      draft:
        "SELECT #{@asset_version_columns} FROM relay.layout_versions v WHERE v.layout_id = $1 AND v.state = 'draft'",
      versions:
        "SELECT #{@asset_version_columns} FROM relay.layout_versions v WHERE v.layout_id = $1 AND v.version_no IS NOT NULL ORDER BY v.version_no DESC",
      version:
        "SELECT #{@asset_version_columns} FROM relay.layout_versions v WHERE v.layout_id = $1 AND v.version_no = $2"
    },
    partial: %{
      get:
        "SELECT #{@asset_columns} FROM relay.partials a WHERE a.key = $1 AND a.subtenant_id IS NOT DISTINCT FROM $2",
      page:
        "SELECT #{@asset_columns} FROM relay.partials a WHERE a.subtenant_id IS NOT DISTINCT FROM $1 AND ($2::uuid IS NULL OR a.id > $2) ORDER BY a.id LIMIT $3",
      draft:
        "SELECT #{@asset_version_columns} FROM relay.partial_versions v WHERE v.partial_id = $1 AND v.state = 'draft'",
      versions:
        "SELECT #{@asset_version_columns} FROM relay.partial_versions v WHERE v.partial_id = $1 AND v.version_no IS NOT NULL ORDER BY v.version_no DESC",
      version:
        "SELECT #{@asset_version_columns} FROM relay.partial_versions v WHERE v.partial_id = $1 AND v.version_no = $2"
    }
  }

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # TP-1
  # TP-48
  # TP-52
  @doc "Creates a template with its first draft; `attrs` carries `:id`, `:version_id`, `:key`, `:subtenant_id`, `:product`, `:name`, `:category` (a category key) and `:definition`."
  @spec template_create(map(), digest(), Actor.t()) :: {atom(), maybe_id(), maybe_id(), version()}
  def template_create(attrs, digest, %Actor{} = actor) do
    params =
      [attrs.id, attrs.version_id, attrs.key, attrs[:subtenant_id], attrs[:product]] ++
        [attrs.name, attrs.category, attrs.definition, digest | Actor.params(actor)]

    [row] = Repo.call!("relay_fn.template_create", params)
    {code(row, @template_create), row["template_id"], row["version_id"], row["version"]}
  end

  # TP-1
  # INV-21
  @doc "Writes the name and category of a template; after the first publication the category must keep the template's class (`:class_locked`)."
  @spec template_update(at(), map(), version(), digest(), Actor.t()) :: {atom(), version()}
  def template_update(at, attrs, expected_version, digest, %Actor{} = actor) do
    params =
      address(at) ++ [attrs.name, attrs.category, expected_version, digest | Actor.params(actor)]

    [row] = Repo.call!("relay_fn.template_update", params)
    {code(row, @template_update ++ @lookup), row["version"]}
  end

  # TP-31
  # TP-48
  @doc "Writes the draft of a template from its definition; returns `:created` when a new draft row is opened, `:replaced` or `:unchanged`."
  @spec template_draft_put(at(), Relay.Id.t(), map(), version(), digest(), Actor.t()) ::
          {atom(), maybe_id(), version()}
  def template_draft_put(at, version_id, definition, expected, digest, %Actor{} = actor) do
    params = [version_id | address(at)] ++ [definition, expected, digest | Actor.params(actor)]
    [row] = Repo.call!("relay_fn.template_draft_put", params)
    {code(row, @template_draft ++ @lookup), row["version_id"], row["version"]}
  end

  # TP-31
  # TP-32
  @doc "Publishes the draft with the gate's result: the variable usage index, the worst-case measures and the findings; warnings publish only with `accept_warnings`."
  @spec template_publish(at(), gate(), version(), digest(), Actor.t()) ::
          {atom(), maybe_id(), version(), version()}
  def template_publish(at, gate, expected_version, digest, %Actor{} = actor) do
    params =
      address(at) ++
        [gate[:checksum], gate.variables, gate.measures, gate.findings, gate.accept_warnings] ++
        [gate[:diff], expected_version, digest | Actor.params(actor)]

    [row] = Repo.call!("relay_fn.template_publish", params)
    result = code(row, @template_publish ++ @gate ++ @lookup)
    {result, row["version_id"], row["version_no"], row["version"]}
  end

  # TP-31
  @doc "Moves the live pointer of a template back to a published version; the caller revalidates the version first."
  @spec template_rollback(at(), pos_integer(), version(), digest(), Actor.t()) ::
          {atom(), maybe_id(), version()}
  def template_rollback(at, version_no, expected_version, digest, %Actor{} = actor) do
    params = address(at) ++ [version_no, expected_version, digest | Actor.params(actor)]
    [row] = Repo.call!("relay_fn.template_rollback", params)
    {code(row, @rollback ++ @lookup), row["version_id"], row["version"]}
  end

  # TP-48
  @doc "Archives a template and its draft; nothing is deleted."
  @spec template_archive(at(), version(), digest(), Actor.t()) :: {atom(), version()}
  def template_archive(at, expected_version, digest, %Actor{} = actor) do
    params = address(at) ++ [expected_version, digest | Actor.params(actor)]
    [row] = Repo.call!("relay_fn.template_archive", params)
    {code(row, [:protected | @archive]), row["version"]}
  end

  # TP-31
  @doc "Archives one published version that is not live, or the draft when `version_no` is `nil`."
  @spec template_version_archive(at(), version(), digest(), Actor.t()) :: atom()
  def template_version_archive(at, version_no, digest, %Actor{} = actor) do
    params = address(at) ++ [version_no, digest | Actor.params(actor)]
    [row] = Repo.call!("relay_fn.template_version_archive", params)

    code(row["template_version_archive"], [
      :archived,
      :already_archived,
      :live_version,
      :version_not_found,
      :not_found,
      :protected
    ])
  end

  # TP-11
  # TP-36
  # TP-51
  @doc "Resolves the live versions of template keys for a workflow step with sub-tenant inheritance: each row carries the template, its live version, the live layout and partial versions it names and, when it cannot render, the `rule_id` (`template.not_published` or `template.archived`)."
  @spec template_live([String.t()], maybe_id()) :: [row()]
  def template_live(keys, subtenant_id) when is_list(keys),
    do: Repo.call!("relay_fn.template_live", [keys, subtenant_id])

  # TP-36
  # TP-52
  @doc "Resolves the brand fields for a template version: sub-tenant over tenant settings, and for a producer template the producer's values with only the four tenant-overridable fields taken from the settings. Returns `%{field => %{value: value, source: source}}`."
  @spec brand_resolve(maybe_id(), maybe_id()) :: %{String.t() => map()}
  def brand_resolve(subtenant_id, template_version_id) do
    for row <- Repo.call!("relay_fn.brand_resolve", [subtenant_id, template_version_id]),
        into: %{},
        do: {row["field"], %{value: row["value"], source: row["source"]}}
  end

  @doc "The template at a key and level, or `nil`."
  @spec template(String.t(), maybe_id()) :: row() | nil
  def template(key, subtenant_id) do
    one(
      """
      SELECT #{@template_columns} FROM relay.templates t
      JOIN relay.categories c ON c.tenant_id = t.tenant_id AND c.environment = t.environment
        AND c.id = t.category_id
      WHERE t.key = $1 AND t.subtenant_id IS NOT DISTINCT FROM $2
      """,
      [key, subtenant_id]
    )
  end

  @doc "A page of the templates of one level ordered by identifier, after `after_id` when given."
  @spec templates(maybe_id(), maybe_id(), pos_integer()) :: [row()]
  def templates(subtenant_id, after_id, limit) do
    maps(
      Repo.scoped_query!(
        """
        SELECT #{@template_columns} FROM relay.templates t
        JOIN relay.categories c ON c.tenant_id = t.tenant_id AND c.environment = t.environment
          AND c.id = t.category_id
        WHERE t.subtenant_id IS NOT DISTINCT FROM $1 AND ($2::uuid IS NULL OR t.id > $2)
        ORDER BY t.id LIMIT $3
        """,
        [subtenant_id, after_id, limit]
      )
    )
  end

  @doc "The draft of a template, or `nil`."
  @spec template_draft(Relay.Id.t()) :: row() | nil
  def template_draft(template_id) do
    one(
      "SELECT #{@template_version_columns} FROM relay.template_versions v WHERE v.template_id = $1 AND v.state = 'draft'",
      [template_id]
    )
  end

  @doc "The published and archived versions of a template, newest first."
  @spec template_versions(Relay.Id.t()) :: [row()]
  def template_versions(template_id) do
    maps(
      Repo.scoped_query!(
        "SELECT #{@template_version_columns} FROM relay.template_versions v WHERE v.template_id = $1 AND v.version_no IS NOT NULL ORDER BY v.version_no DESC",
        [template_id]
      )
    )
  end

  @doc "One numbered version of a template, or `nil`."
  @spec template_version(Relay.Id.t(), pos_integer()) :: row() | nil
  def template_version(template_id, version_no) do
    one(
      "SELECT #{@template_version_columns} FROM relay.template_versions v WHERE v.template_id = $1 AND v.version_no = $2",
      [template_id, version_no]
    )
  end

  # TP-35
  @doc "Creates a layout or partial with its first draft; `attrs` carries `:id`, `:version_id`, `:key`, `:subtenant_id`, `:name` and `:content`."
  @spec asset_create(kind(), map(), digest(), Actor.t()) ::
          {atom(), maybe_id(), maybe_id(), version()}
  def asset_create(kind, attrs, digest, %Actor{} = actor) when kind in [:layout, :partial] do
    params =
      [attrs.id, attrs.version_id, attrs.key, attrs[:subtenant_id], attrs.name, attrs.content] ++
        [digest | Actor.params(actor)]

    [row] = Repo.call!("relay_fn.#{kind}_create", params)
    result = code(row, [:created, :key_conflict, :subtenant_not_found, :tenant_inactive])
    {result, row["#{kind}_id"], row["version_id"], row["version"]}
  end

  # TP-35
  @doc "Writes the name and draft content of a layout or partial."
  @spec asset_draft_put(kind(), at(), Relay.Id.t(), map(), version(), digest(), Actor.t()) ::
          {atom(), maybe_id(), version()}
  def asset_draft_put(kind, at, version_id, attrs, expected_version, digest, %Actor{} = actor)
      when kind in [:layout, :partial] do
    params =
      [version_id, at.key, at[:subtenant_id], attrs.name, attrs.content, expected_version] ++
        [digest | Actor.params(actor)]

    [row] = Repo.call!("relay_fn.#{kind}_draft_put", params)
    {code(row, @asset_draft), row["version_id"], row["version"]}
  end

  # TP-31
  # TP-35
  @doc "Publishes the draft of a layout or partial with the gate's findings."
  @spec asset_publish(kind(), at(), map(), version(), digest(), Actor.t()) ::
          {atom(), maybe_id(), version(), version()}
  def asset_publish(kind, at, gate, expected_version, digest, %Actor{} = actor)
      when kind in [:layout, :partial] do
    params =
      [at.key, at[:subtenant_id], gate[:checksum], gate.findings, gate.accept_warnings] ++
        [gate[:diff], expected_version, digest | Actor.params(actor)]

    [row] = Repo.call!("relay_fn.#{kind}_publish", params)
    result = code(row, [:published, :not_found, :archived, :version_conflict] ++ @gate)
    {result, row["version_id"], row["version_no"], row["version"]}
  end

  # TP-31
  @doc "Moves the live pointer of a layout or partial back to a published version."
  @spec asset_rollback(kind(), at(), pos_integer(), version(), digest(), Actor.t()) ::
          {atom(), maybe_id(), version()}
  def asset_rollback(kind, at, version_no, expected_version, digest, %Actor{} = actor)
      when kind in [:layout, :partial] do
    params =
      [at.key, at[:subtenant_id], version_no, expected_version, digest | Actor.params(actor)]

    [row] = Repo.call!("relay_fn.#{kind}_rollback", params)
    result = code(row, @rollback ++ [:not_found, :archived, :version_conflict])
    {result, row["version_id"], row["version"]}
  end

  # TP-48
  @doc "Archives a layout or partial; one used by a live template version is `:in_use`."
  @spec asset_archive(kind(), at(), version(), digest(), Actor.t()) :: {atom(), version()}
  def asset_archive(kind, at, expected_version, digest, %Actor{} = actor)
      when kind in [:layout, :partial] do
    params = [at.key, at[:subtenant_id], expected_version, digest | Actor.params(actor)]
    [row] = Repo.call!("relay_fn.#{kind}_archive", params)
    {code(row, [:in_use | @archive]), row["version"]}
  end

  @doc "The layout or partial at a key and level, or `nil`."
  @spec asset(kind(), String.t(), maybe_id()) :: row() | nil
  def asset(kind, key, subtenant_id) when kind in [:layout, :partial],
    do: one(@asset_sql[kind].get, [key, subtenant_id])

  @doc "A page of the layouts or partials of one level ordered by identifier."
  @spec assets(kind(), maybe_id(), maybe_id(), pos_integer()) :: [row()]
  def assets(kind, subtenant_id, after_id, limit) when kind in [:layout, :partial],
    do: maps(Repo.scoped_query!(@asset_sql[kind].page, [subtenant_id, after_id, limit]))

  @doc "The draft of a layout or partial, or `nil`."
  @spec asset_draft(kind(), Relay.Id.t()) :: row() | nil
  def asset_draft(kind, id) when kind in [:layout, :partial],
    do: one(@asset_sql[kind].draft, [id])

  @doc "The numbered versions of a layout or partial, newest first."
  @spec asset_versions(kind(), Relay.Id.t()) :: [row()]
  def asset_versions(kind, id) when kind in [:layout, :partial],
    do: maps(Repo.scoped_query!(@asset_sql[kind].versions, [id]))

  @doc "One numbered version of a layout or partial, or `nil`."
  @spec asset_version(kind(), Relay.Id.t(), pos_integer()) :: row() | nil
  def asset_version(kind, id, version_no) when kind in [:layout, :partial],
    do: one(@asset_sql[kind].version, [id, version_no])

  # TP-50
  # INV-48
  @doc "Pins the render plan of a delivery at creation: the template version, the layout version, the partial versions and the resolved locale; a pinned plan never changes (`:exists`)."
  @spec plan_pin(Relay.Id.t(), map()) :: atom()
  def plan_pin(delivery_id, plan) do
    params = [
      delivery_id,
      plan.template_version_id,
      plan[:layout_version_id],
      Map.get(plan, :partial_version_ids, []),
      plan.locale,
      Map.get(plan, :locale_fallback, false)
    ]

    [row] = Repo.call!("relay_fn.delivery_plan_pin", params)

    code(row["delivery_plan_pin"], [
      :pinned,
      :exists,
      :delivery_not_found,
      :version_not_published,
      :layout_not_published,
      :partial_not_published
    ])
  end

  @doc "The pinned render plan of a delivery, or `nil`."
  @spec plan(Relay.Id.t()) :: row() | nil
  def plan(delivery_id) do
    one(
      """
      SELECT p.tenant_id, p.environment::text AS environment, p.delivery_id, p.template_id,
        p.template_version_id, p.layout_version_id, p.partial_version_ids, p.locale,
        p.locale_fallback, p.render_digest, p.render_measures, p.rendered_at, p.render_count,
        p.created_at, p.updated_at
      FROM relay.delivery_render_plans p WHERE p.delivery_id = $1
      """,
      [delivery_id]
    )
  end

  # TP-40
  @doc "How the render content of a delivery is kept: `digest_reason` (`security_subtype`, `retention_none` or `nil` when the content is kept), the `retention_class` and the recipient's active subject key of that class to seal it under."
  @spec render_policy(Relay.Id.t()) :: row()
  def render_policy(delivery_id) do
    [row] = Repo.call!("relay_fn.delivery_render_policy", [delivery_id])
    row
  end

  # TP-40
  # TP-50
  @doc "Records a render: the first records the digest, the measures and the content snapshot (`content_ct` sealed under `key_id`, or both `nil` for a digest-only snapshot); a retry returns `:matched` or `:digest_mismatch`."
  @spec render_record(Relay.Id.t(), digest(), map(), binary() | nil, maybe_id()) :: atom()
  def render_record(delivery_id, digest, measures, content_ct, key_id) do
    params = [delivery_id, digest, measures, content_ct, key_id]
    [row] = Repo.call!("relay_fn.delivery_render_record", params)

    code(row["delivery_render_record"], [
      :recorded,
      :matched,
      :digest_mismatch,
      :content_not_allowed,
      :content_required,
      :key_invalid,
      :plan_not_found,
      :delivery_not_found,
      :already_terminal
    ])
  end

  # TP-41
  # INV-46
  # IN-49
  @doc "Fails a delivery for a render failure (`:missing_variable`, `:render_timeout`, `:output_too_large`, `:schema_violation` or, for an inbox item over the published limits, `:inbox_item_too_large`) with its ledger event and the `notification.render_failed` event; there is no retry."
  @spec render_fail(Relay.Id.t(), atom(), map()) :: atom()
  def render_fail(delivery_id, reason, detail \\ %{})
      when reason in [
             :missing_variable,
             :render_timeout,
             :output_too_large,
             :schema_violation,
             :inbox_item_too_large
           ] do
    params = [delivery_id, Atom.to_string(reason), detail]
    [row] = Repo.call!("relay_fn.delivery_render_fail", params)

    code(row["delivery_render_fail"], [:failed, :already_terminal, :not_found])
  end

  # API-56
  @doc "A page of the templates of one level, newest first, after or before a cursor position (`%{direction: :after | :before, sort_ts_us: integer, id: id}`); at most `limit + 1` rows, each with its sort time as `cursor_at`."
  @spec template_page(maybe_id(), map() | nil, pos_integer()) :: [row()]
  def template_page(subtenant_id, cursor, limit) do
    %{
      from: """
      relay.templates t JOIN relay.categories c ON c.tenant_id = t.tenant_id
        AND c.environment = t.environment AND c.id = t.category_id
      """,
      columns: @template_columns,
      alias: "t",
      where: "t.subtenant_id IS NOT DISTINCT FROM $1",
      params: [subtenant_id],
      sort: "created_at"
    }
    |> page(cursor, limit)
  end

  # API-56
  @doc "A page of the published and archived versions of a template, newest publication first; see `template_page/3` for the cursor."
  @spec template_version_page(Relay.Id.t(), map() | nil, pos_integer()) :: [row()]
  def template_version_page(template_id, cursor, limit) do
    %{
      from: "relay.template_versions v",
      columns: @template_version_columns,
      alias: "v",
      where: "v.template_id = $1 AND v.version_no IS NOT NULL",
      params: [template_id],
      sort: "published_at"
    }
    |> page(cursor, limit)
  end

  # API-56
  @doc "A page of the layouts or partials of one level, newest first; see `template_page/3` for the cursor."
  @spec asset_page(kind(), maybe_id(), map() | nil, pos_integer()) :: [row()]
  def asset_page(kind, subtenant_id, cursor, limit) when kind in [:layout, :partial] do
    %{
      from: "relay.#{kind}s a",
      columns: @asset_columns,
      alias: "a",
      where: "a.subtenant_id IS NOT DISTINCT FROM $1",
      params: [subtenant_id],
      sort: "created_at"
    }
    |> page(cursor, limit)
  end

  # API-56
  @doc "A page of the published and archived versions of a layout or partial, newest publication first; see `template_page/3` for the cursor."
  @spec asset_version_page(kind(), Relay.Id.t(), map() | nil, pos_integer()) :: [row()]
  def asset_version_page(kind, id, cursor, limit) when kind in [:layout, :partial] do
    %{
      from: "relay.#{kind}_versions v",
      columns: @asset_version_columns,
      alias: "v",
      where: "v.#{kind}_id = $1 AND v.version_no IS NOT NULL",
      params: [id],
      sort: "published_at"
    }
    |> page(cursor, limit)
  end

  defp page(spec, cursor, limit) do
    %{alias: as, sort: sort, params: params} = spec

    {condition, order, params} =
      case cursor do
        nil ->
          {"", "DESC", params}

        %{direction: :after, sort_ts_us: ts, id: id} ->
          n = length(params)

          {" AND (#{as}.#{sort}, #{as}.id) < ($#{n + 1}, $#{n + 2})", "DESC",
           params ++ [at(ts), id]}

        %{direction: :before, sort_ts_us: ts, id: id} ->
          n = length(params)

          {" AND (#{as}.#{sort}, #{as}.id) > ($#{n + 1}, $#{n + 2})", "ASC",
           params ++ [at(ts), id]}
      end

    sql = """
    SELECT #{spec.columns}, #{as}.#{sort} AS cursor_at FROM #{spec.from}
    WHERE #{spec.where}#{condition}
    ORDER BY #{as}.#{sort} #{order}, #{as}.id #{order}
    LIMIT #{limit + 1}
    """

    rows = maps(Repo.scoped_query!(sql, params))
    if order == "ASC", do: Enum.reverse(rows), else: rows
  end

  defp at(us), do: DateTime.from_unix!(us, :microsecond)

  # TP-35
  # TP-36
  @doc "The brand fields at a level (`nil` for the tenant level): each field's effective value and its source (`subtenant`, `tenant` or `none`), with the sum of the versions of the brand settings stored at that level, which grows with every change."
  @spec brand(maybe_id()) :: {%{String.t() => brand_field()}, non_neg_integer()}
  def brand(subtenant_id) do
    keys = Enum.map(@brand_fields, &("brand." <> &1))

    fields =
      for row <- Repo.call!("relay_fn.setting_resolve", [subtenant_id, keys]), into: %{} do
        "brand." <> field = row["key"]
        {field, %{value: row["value"], source: row["source"]}}
      end

    versions =
      Repo.scoped_query!(
        """
        SELECT s.tenant_id, s.environment::text AS environment, s.version FROM relay.settings s
        WHERE s.subtenant_id IS NOT DISTINCT FROM $1 AND s.key = ANY($2)
        """,
        [subtenant_id, keys]
      )

    {fields, versions |> maps() |> Enum.map(& &1["version"]) |> Enum.sum()}
  end

  # TP-35
  # TP-36
  @doc "Sets or clears (`nil`) one brand field at a level; the value is checked by the caller."
  @spec brand_put(maybe_id(), String.t(), String.t() | nil, digest(), Actor.t()) :: atom()
  def brand_put(subtenant_id, field, value, digest, %Actor{} = actor)
      when field in @brand_fields do
    params = [subtenant_id, "brand." <> field, value, nil, digest | Actor.params(actor)]
    [row] = Repo.call!("relay_fn.setting_set", params)
    code(row, [:created, :updated, :unchanged, :cleared, :version_conflict, :subtenant_not_found])
  end

  # DS-29
  @doc "The value of a tenant-level setting, `nil` when it is not set."
  @spec tenant_setting(String.t()) :: term()
  def tenant_setting(key) do
    sql = """
    SELECT s.tenant_id, s.environment::text AS environment, s.value FROM relay.settings s
    WHERE s.subtenant_id IS NULL AND s.key = $1
    """

    case one(sql, [key]) do
      nil -> nil
      row -> row["value"]
    end
  end

  # DS-29
  @doc "Sets or clears (`nil`) a tenant-level setting; the key and value are checked by the caller."
  @spec tenant_setting_put(String.t(), term(), digest(), Actor.t()) :: atom()
  def tenant_setting_put(key, value, digest, %Actor{} = actor) do
    params = [nil, key, value, nil, digest | Actor.params(actor)]
    [row] = Repo.call!("relay_fn.setting_set", params)
    code(row, [:created, :updated, :unchanged, :cleared, :version_conflict, :subtenant_not_found])
  end

  @doc "The brand field names."
  @spec brand_fields() :: [String.t()]
  def brand_fields, do: @brand_fields

  # TP-36
  @doc "Whether an active sub-tenant has this identifier in the scope."
  @spec subtenant?(Relay.Id.t()) :: boolean()
  def subtenant?(id) do
    sql = """
    SELECT s.tenant_id, s.environment::text AS environment, s.id FROM relay.subtenants s
    WHERE s.id = $1 AND s.state = 'active'
    """

    one(sql, [id]) != nil
  end

  # TP-33
  # TP-56
  @doc "The region, default locale and default time zone of the scope's tenant."
  @spec tenant_facts() :: %{
          region: String.t(),
          default_locale: String.t(),
          default_timezone: String.t()
        }
  def tenant_facts do
    sql = "SELECT region, default_locale, default_timezone FROM relay.tenants"
    [row] = maps(Repo.scoped_query!(sql, []))

    %{
      region: row["region"],
      default_locale: row["default_locale"],
      default_timezone: row["default_timezone"]
    }
  end

  # TP-38
  # TP-47
  @doc "The newest accepted events of a workflow created at or after `since` whose content is kept (neither `retention: none` nor a security subtype, payload not erased), newest first, at most `limit`; each carries its encrypted `data_ct` and `key_id`. Nothing is decrypted or stored."
  @spec recent_events(String.t(), DateTime.t(), pos_integer()) :: [row()]
  def recent_events(workflow_key, %DateTime{} = since, limit) do
    maps(
      Repo.scoped_query!(
        """
        SELECT e.tenant_id, e.environment::text AS environment, e.id, e.created_at, p.data_ct,
          p.key_id
        FROM relay.events e
        JOIN relay.workflows w ON w.tenant_id = e.tenant_id AND w.environment = e.environment
          AND w.id = e.workflow_id
        JOIN relay.event_payloads p ON p.tenant_id = e.tenant_id AND p.environment = e.environment
          AND p.event_id = e.id AND p.created_at = e.payload_created_at
        WHERE w.key = $1 AND e.state = 'accepted' AND NOT e.retention_none
          AND e.security_subtype IS NULL AND e.created_at >= $2 AND p.erased_at IS NULL
          AND p.data_ct IS NOT NULL
        ORDER BY e.created_at DESC, e.id DESC
        LIMIT $3
        """,
        [workflow_key, since, limit]
      )
    )
  end

  defp address(at), do: [at.key, at[:subtenant_id], at[:product]]

  defp code(%{"result" => text}, codes), do: Repo.code!(text, codes)
  defp code(text, codes) when is_binary(text), do: Repo.code!(text, codes)

  defp one(sql, params) do
    case maps(Repo.scoped_query!(sql, params)) do
      [row] -> row
      [] -> nil
    end
  end

  defp maps(%Postgrex.Result{columns: columns, rows: rows}),
    do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
end
