defmodule Relay.Api.Templates do
  @moduledoc """
  Template management on the server API (API-69, TP-1, TP-31, TP-32, TP-48, TP-52): list, create with a first draft (`201`), read, replace the draft and the name or category under `If-Match`, publish the draft through the publication gate, archive, list and read versions, promote an old version back to live after revalidating it, the translation matrix, and the producer publication of a protected template.

  A resource is addressed by its key and level (`at`: `:key`, `:subtenant_id`, and `:product` for a producer). The publication gate runs before the write transaction, since the MJML compiler leaves the BEAM (TP-8): its findings are bound to the checksum of the draft they were computed on, so a draft changed in between is `template_draft_changed`. A tenant writing a producer template gets `template_protected`; a producer changes only its own templates, and the tenant changes only the brand fields `logo_url`, `primary_color`, `sender_name` and `footer` of them (TP-52).
  """

  alias Relay.Api.Gate
  alias Relay.Api.Page
  alias Relay.Api.Views
  alias Relay.TemplateStore

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}
  @type at :: %{
          required(:key) => String.t(),
          required(:subtenant_id) => Relay.Id.t() | nil,
          optional(:product) => String.t() | nil
        }

  @overridable ["logo_url", "primary_color", "sender_name", "footer"]
  @countries %{"tr" => "TR", "us" => "US"}

  # TP-48
  @doc "The API view of a template row and its draft row."
  @spec view(map(), map() | nil) :: map()
  def view(t, draft) do
    %{
      "object" => "template",
      "id" => Views.id("tpl", t["id"]),
      "key" => t["key"],
      "name" => t["name"],
      "owner" => t["owner"],
      "product" => t["owner_product"],
      "subtenant" => Views.id("stn", t["subtenant_id"]),
      "category" => t["category"],
      "message_class" => t["message_class"],
      "type" => t["template_type"],
      "protected" => t["owner"] == "producer",
      "state" => t["state"],
      "live_version" => t["live_version_no"],
      "draft" => draft && definition(draft),
      "draft_checksum" => draft && Gate.hex(draft["checksum"]),
      "version" => t["version"],
      "created_at" => t["created_at"],
      "updated_at" => t["updated_at"]
    }
  end

  # TP-31
  @doc "The API view of a published or archived template version."
  @spec version_view(String.t(), map(), Relay.Id.t() | nil) :: map()
  def version_view(key, v, live_id) do
    %{
      "object" => "template_version",
      "id" => Views.id("tpv", v["id"]),
      "template_key" => key,
      "version" => v["version_no"],
      "state" => v["state"],
      "live" => v["id"] == live_id,
      "definition" => definition(v),
      "checksum" => Gate.hex(v["checksum"]),
      "variables" => v["variables"] || %{"always" => [], "conditional" => []},
      "measures" => v["measures"] || %{},
      "findings" => v["findings"] || [],
      "warnings_accepted" => v["warnings_accepted"],
      "warnings_accepted_by" => v["warnings_accepted_by_ref"],
      "previous_version" => v["previous_version_no"],
      "diff" => v["diff"],
      "published_at" => v["published_at"],
      "published_by" => v["published_by_ref"]
    }
  end

  # TP-48
  @doc "The template definition of a version row, the shape the API and the file format accept."
  @spec definition(map()) :: map()
  def definition(v) do
    %{
      "default_locale" => v["default_locale"],
      "sensitivity" => v["sensitivity"],
      "sensitivity_approval" => v["sensitivity_approval"],
      "sms_encoding" => v["sms_encoding"],
      "transliterate" => v["transliterate"],
      "allow_raw" => v["allow_raw"],
      "layout" => v["layout_key"],
      "partials" => v["partial_keys"] || [],
      "producer_brand" => v["producer_brand"],
      "cells" => v["cells"]
    }
  end

  @doc "The ETag header of a template version number."
  @spec etag(pos_integer()) :: {String.t(), String.t()}
  def etag(version), do: {"etag", ~s("#{version}")}

  # TP-1
  # TP-48
  @doc "Creates a template with its first draft inside the request's transaction; `201` with its view."
  @spec create(Relay.Scope.t(), at(), map(), Relay.Actor.t()) :: answer()
  def create(scope, at, body, actor) do
    definition = body["definition"]

    with :ok <- definition_rules(definition, at[:product] != nil) do
      attrs = %{
        id: Relay.Id.generate(),
        version_id: Relay.Id.generate(),
        key: body["key"],
        subtenant_id: at.subtenant_id,
        product: at[:product],
        name: body["name"],
        category: body["category"],
        definition: definition
      }

      digest = Gate.digest(scope, "template.created", body["key"])

      case TemplateStore.template_create(attrs, digest, actor) do
        {:created, _id, _version_id, version} ->
          at = Map.put(at, :key, body["key"])
          location = {"location", "/v1/templates/" <> body["key"]}
          {:ok, {201, [etag(version), location], current(at)}}

        {code, _id, _version_id, _version} ->
          {:error, create_error(code)}
      end
    end
  end

  defp create_error(:key_conflict),
    do: Relay.Error.new(:resource_conflict, "a template with this key exists at this level")

  defp create_error(:subtenant_not_found),
    do: Gate.field_error("/subtenant", "not_found", "no subtenant has this id")

  defp create_error(:category_not_found),
    do: Gate.field_error("/category", "not_found", "no category has this key")

  defp create_error(:category_archived), do: category_archived()

  defp create_error(:layout_not_found),
    do: Gate.field_error("/definition/layout", "not_found", "no active layout has this key")

  defp create_error(:partial_not_found),
    do: Gate.field_error("/definition/partials", "not_found", "a partial does not exist")

  defp create_error(:tenant_inactive),
    do: Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")

  # TP-48
  # TP-52
  # TP-56
  @doc "The request rules of a definition the schema cannot express: only a producer sets `producer_brand`, and every locale is supported."
  @spec definition_rules(map(), boolean()) :: :ok | {:error, Relay.Error.t()}
  def definition_rules(definition, producer?) do
    cond do
      not producer? and definition["producer_brand"] != nil ->
        {:error,
         Gate.field_error("/definition/producer_brand", "not_allowed", "only a producer sets it")}

      not Enum.all?(locales(definition), &Relay.Templates.locale_supported?/1) ->
        {:error, Relay.Error.new(:locale_not_supported, "a template locale is not supported")}

      true ->
        :ok
    end
  end

  defp locales(definition) do
    cells = for {_key, _channel, locale, _cell} <- Relay.Templates.cells(definition), do: locale
    Enum.uniq([definition["default_locale"] | cells])
  end

  # TP-31
  # TP-48
  # INV-21
  @doc "Replaces the draft of a template, and its name or category when the body names them, inside the request's transaction."
  @spec replace(Relay.Scope.t(), at(), map(), pos_integer(), Relay.Actor.t()) :: answer()
  def replace(scope, at, body, expected, actor) do
    definition = body["definition"]

    with {:ok, t} <- found(at),
         :ok <- definition_rules(definition, t["owner"] == "producer"),
         {:ok, expected} <- rename(scope, at, t, body, expected, actor) do
      digest = Gate.digest(scope, "template.drafted", at.key)
      id = Relay.Id.generate()

      case TemplateStore.template_draft_put(at, id, definition, expected, digest, actor) do
        {result, _id, version} when result in [:created, :replaced, :unchanged] ->
          {:ok, {200, [etag(version)], current(at)}}

        {code, _id, _version} ->
          {:error, write_error(code)}
      end
    end
  end

  defp rename(scope, at, t, body, expected, actor) do
    name = Map.get(body, "name", t["name"])
    category = Map.get(body, "category", t["category"])

    if name == t["name"] and category == t["category"] do
      {:ok, expected}
    else
      attrs = %{name: name, category: category}
      digest = Gate.digest(scope, "template.updated", at.key)

      case TemplateStore.template_update(at, attrs, expected, digest, actor) do
        {result, version} when result in [:updated, :unchanged] -> {:ok, version}
        {code, _version} -> {:error, write_error(code)}
      end
    end
  end

  defp write_error(:not_found), do: not_found()
  defp write_error(:archived), do: archived()
  defp write_error(:protected), do: protected()
  defp write_error(:version_conflict), do: precondition_failed()
  defp write_error(:category_not_found), do: category_not_found()
  defp write_error(:category_archived), do: category_archived()

  defp write_error(:class_locked),
    do:
      Relay.Error.new(
        :template_class_mismatch,
        "a published template keeps its message class; choose a category of the same class"
      )

  defp write_error(:layout_not_found),
    do: Relay.Error.new(:layout_not_found, "no active layout has this key")

  defp write_error(:partial_not_found),
    do: Relay.Error.new(:partial_not_found, "a partial the template names does not exist")

  # TP-48
  @doc "Archives a template and its draft inside the request's transaction; nothing is deleted."
  @spec archive(Relay.Scope.t(), at(), pos_integer(), Relay.Actor.t()) :: answer()
  def archive(scope, at, expected, actor) do
    digest = Gate.digest(scope, "template.archived", at.key)

    case TemplateStore.template_archive(at, expected, digest, actor) do
      {result, version} when result in [:archived, :already_archived] ->
        {:ok, {200, [etag(version)], current(at)}}

      {code, _version} ->
        {:error, write_error(code)}
    end
  end

  # TP-31
  # TP-32
  @doc "Prepares a publication outside any transaction: reads the draft and its inputs and runs the publication gate. The result is handed to `publish/5`."
  @spec prepare_publish(Relay.Scope.t(), at(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def prepare_publish(scope, at, body) do
    read =
      TemplateStore.in_scope(scope, fn _status ->
        with {:ok, t} <- found(at),
             :ok <- owned(t, at),
             :ok <- active(t),
             {:ok, draft} <- draft(t) do
          inputs(at, t, draft)
        end
      end)

    with {:ok, {:ok, inputs}} <- read,
         :ok <- reviewed(body, inputs.draft) do
      gate = run_gate(inputs, definition(inputs.draft))
      accept = Map.get(body || %{}, "accept_warnings", false) == true

      with :ok <- Gate.outcome(gate.findings, accept, :template),
           do: {:ok, Map.merge(inputs, %{gate: gate, accept: accept})}
    else
      {:ok, {:error, error}} -> {:error, error}
      {:error, %Relay.Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp reviewed(%{"checksum" => checksum}, draft) when is_binary(checksum) do
    if checksum == Gate.hex(draft["checksum"]), do: :ok, else: {:error, draft_changed()}
  end

  defp reviewed(_body, _draft), do: :ok

  defp inputs(at, t, draft) do
    live = t["live_version_no"] && TemplateStore.template_version(t["id"], t["live_version_no"])

    {:ok,
     %{
       template: t,
       draft: draft,
       live: live,
       schemas: schemas(at.key),
       brand: brand(at, draft["id"]),
       country: country()
     }}
  end

  defp schemas(key), do: Enum.map(Relay.Workflow.using_template(key), & &1["event_schema"])

  defp brand(at, version_id) do
    for {field, %{value: value}} <- TemplateStore.brand_resolve(at.subtenant_id, version_id),
        value != nil,
        into: %{},
        do: {field, value}
  end

  defp country, do: Map.get(@countries, TemplateStore.tenant_facts().region)

  defp run_gate(inputs, definition) do
    terms = Gate.terms()

    Relay.Templates.publish_gate(%{
      definition: definition,
      message_class: inputs.template["message_class"],
      schemas: inputs.schemas,
      brand: inputs.brand,
      country: inputs.country,
      sensitive_terms: terms.sensitive,
      promotional_terms: terms.promotional,
      compile: &Relay.Templates.compile_mjml/1
    })
  end

  # TP-31
  # TP-32
  @doc "Publishes the draft a prepared gate ran on inside the request's transaction; `200` with the new version."
  @spec publish(Relay.Scope.t(), at(), map(), pos_integer(), Relay.Actor.t()) :: answer()
  def publish(scope, at, prepared, expected, actor) do
    live = prepared.live && definition(prepared.live)

    gate = %{
      variables: prepared.gate.variables,
      measures: prepared.gate.measures,
      findings: Enum.map(prepared.gate.findings, &Gate.view/1),
      accept_warnings: prepared.accept,
      checksum: prepared.draft["checksum"],
      diff: Gate.diff(live, definition(prepared.draft))
    }

    digest = Gate.digest(scope, "template.published", at.key)

    case TemplateStore.template_publish(at, gate, expected, digest, actor) do
      {:published, _id, version_no, version} ->
        {:ok, {200, [etag(version)], published_view(at, version_no)}}

      {code, _id, _version_no, _version} ->
        {:error, publish_error(code, prepared.gate.findings)}
    end
  end

  defp published_view(at, version_no) do
    t = TemplateStore.template(at.key, at.subtenant_id)
    v = TemplateStore.template_version(t["id"], version_no)
    version_view(at.key, v, t["live_version_id"])
  end

  defp publish_error(:no_draft, _findings), do: no_draft()
  defp publish_error(:draft_changed, _findings), do: draft_changed()
  defp publish_error(:gate_failed, findings), do: Gate.gate_failed(findings)

  defp publish_error(:warnings_unaccepted, findings) do
    {:error, error} = Gate.outcome(findings, false, :template)
    error
  end

  defp publish_error(:duplicate, _findings),
    do:
      Relay.Error.new(
        :template_version_duplicate,
        "the draft is identical to a published version; promote that version instead"
      )

  defp publish_error(:sensitivity_missing, _findings),
    do: Relay.Error.new(:template_sensitivity_unconfirmed, "choose the sensitivity class")

  defp publish_error(:translation_unapproved, _findings),
    do:
      Relay.Error.new(
        :template_translation_unapproved,
        "a machine translated cell needs a person's approval"
      )

  defp publish_error(:layout_not_published, _findings),
    do: Relay.Error.new(:layout_not_published, "publish the layout the template names first")

  defp publish_error(:partial_not_published, _findings),
    do: Relay.Error.new(:partial_not_published, "publish the partials the template names first")

  defp publish_error(code, _findings), do: write_error(code)

  # TP-31
  @doc "Prepares a promotion outside any transaction: reads the version and revalidates it through the publication gate; only a hard finding refuses it."
  @spec prepare_promote(Relay.Scope.t(), at(), pos_integer()) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def prepare_promote(scope, at, number) do
    read =
      TemplateStore.in_scope(scope, fn _status ->
        with {:ok, t} <- found(at),
             :ok <- owned(t, at),
             {:ok, v} <- numbered(t, number) do
          inputs(at, t, v)
        end
      end)

    case read do
      {:ok, {:ok, inputs}} ->
        gate = run_gate(inputs, definition(inputs.draft))
        hard = Enum.filter(gate.findings, &(&1.level == :hard))
        if hard == [], do: {:ok, inputs}, else: {:error, Gate.gate_failed(hard)}

      {:ok, {:error, error}} ->
        {:error, error}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # TP-31
  @doc "Moves the live pointer back to a revalidated version inside the request's transaction; no version is created."
  @spec promote(Relay.Scope.t(), at(), pos_integer(), pos_integer(), Relay.Actor.t()) :: answer()
  def promote(scope, at, number, expected, actor) do
    digest = Gate.digest(scope, "template.rolled_back", at.key)

    case TemplateStore.template_rollback(at, number, expected, digest, actor) do
      {result, _id, version} when result in [:rolled_back, :unchanged] ->
        {:ok, {200, [etag(version)], current(at)}}

      {:version_not_found, _id, _version} ->
        {:error, version_not_found()}

      {:version_archived, _id, _version} ->
        {:error,
         Relay.Error.new(:template_version_archived, "an archived version cannot become live")}

      {code, _id, _version} ->
        {:error, write_error(code)}
    end
  end

  # API-56
  @doc "Lists the templates of a level."
  @spec list(Relay.Scope.t(), Relay.Id.t() | nil, Relay.Api.Pagination.page(), String.t()) ::
          answer()
  def list(scope, subtenant_id, page, endpoint) do
    read =
      TemplateStore.in_scope(scope, fn _status ->
        for t <- TemplateStore.template_page(subtenant_id, page.cursor, page.limit),
            do: Map.put(t, "draft", TemplateStore.template_draft(t["id"]))
      end)

    case read do
      {:ok, rows} ->
        position = &{&1["cursor_at"], &1["id"]}
        view = &view(&1, &1["draft"])

        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, view, position),
             do: {:ok, {200, [], body}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  @doc "Reads a template."
  @spec get(Relay.Scope.t(), at()) :: answer()
  def get(scope, at) do
    read =
      TemplateStore.in_scope(scope, fn _status ->
        with {:ok, t} <- found(at), do: {:ok, t, TemplateStore.template_draft(t["id"])}
      end)

    case read do
      {:ok, {:ok, t, draft}} -> {:ok, {200, [etag(t["version"])], view(t, draft)}}
      {:ok, {:error, error}} -> {:error, error}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # API-56
  # TP-31
  @doc "Lists the published and archived versions of a template."
  @spec versions(Relay.Scope.t(), at(), Relay.Api.Pagination.page(), String.t()) :: answer()
  def versions(scope, at, page, endpoint) do
    read =
      TemplateStore.in_scope(scope, fn _status ->
        with {:ok, t} <- found(at),
             do: {:ok, t, TemplateStore.template_version_page(t["id"], page.cursor, page.limit)}
      end)

    case read do
      {:ok, {:ok, t, rows}} ->
        position = &{&1["cursor_at"], &1["id"]}
        view = &version_view(at.key, &1, t["live_version_id"])

        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, view, position),
             do: {:ok, {200, [], body}}

      {:ok, {:error, error}} ->
        {:error, error}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # TP-31
  @doc "Reads one published or archived version of a template."
  @spec version(Relay.Scope.t(), at(), pos_integer()) :: answer()
  def version(scope, at, number) do
    read =
      TemplateStore.in_scope(scope, fn _status ->
        with {:ok, t} <- found(at),
             {:ok, v} <- numbered(t, number),
             do: {:ok, version_view(at.key, v, t["live_version_id"])}
      end)

    case read do
      {:ok, {:ok, view}} -> {:ok, {200, [], view}}
      {:ok, {:error, error}} -> {:error, error}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # TP-30
  @doc "The translation matrix of a template from its draft or its live version: every channel × locale cell is `present`, `missing`, `machine_translated` or `approved`."
  @spec translations(Relay.Scope.t(), at(), String.t()) :: answer()
  def translations(scope, at, source) do
    read =
      TemplateStore.in_scope(scope, fn _status ->
        with {:ok, t} <- found(at), do: matrix_source(t, source)
      end)

    case read do
      {:ok, {:ok, source, v}} -> {:ok, {200, [], matrix(at.key, source, v)}}
      {:ok, {:error, error}} -> {:error, error}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp matrix_source(t, "draft") do
    case TemplateStore.template_draft(t["id"]) do
      nil -> matrix_source(t, "live")
      draft -> {:ok, "draft", draft}
    end
  end

  defp matrix_source(%{"live_version_no" => nil}, "live"),
    do: {:error, Relay.Error.new(:template_not_found, "the template has no live version")}

  defp matrix_source(t, "live"),
    do: {:ok, "live", TemplateStore.template_version(t["id"], t["live_version_no"])}

  defp matrix(key, source, v) do
    definition = definition(v)
    cells = Relay.Templates.cells(definition)
    locales = Enum.sort(Enum.uniq([definition["default_locale"] | Enum.map(cells, &elem(&1, 2))]))
    channels = cells |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

    %{
      "object" => "template_translations",
      "template_key" => key,
      "source" => source,
      "version" => v["version_no"],
      "default_locale" => definition["default_locale"],
      "locales" => locales,
      "cells" =>
        for channel <- channels, locale <- locales do
          cell = get_in(definition, ["cells", channel, locale])
          %{"channel" => channel, "locale" => locale, "status" => status(cell)}
        end
    }
  end

  defp status(nil), do: "missing"

  defp status(%{"machine_translated" => true} = cell) do
    if cell["translation_approved_by"] in [nil, ""], do: "machine_translated", else: "approved"
  end

  defp status(_cell), do: "present"

  # TP-37
  # TP-52
  @doc "Prepares a producer publication outside any transaction: the producer product of the credential's tenant, the template at the key if any, the category's class, and the gate over the definition of the body."
  @spec prepare_producer(Relay.Scope.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def prepare_producer(scope, key, body) do
    read =
      TemplateStore.in_scope(scope, fn _status ->
        with {:ok, product} <- producer(),
             {:ok, category} <- category(body["category"]) do
          at = %{key: key, subtenant_id: nil, product: product}
          t = TemplateStore.template(key, nil)
          producer_inputs(at, t, category, body)
        end
      end)

    case read do
      {:ok, {:ok, inputs}} -> producer_gate(inputs, body)
      {:ok, {:error, error}} -> {:error, error}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp producer do
    case Relay.Ingest.platform_product() do
      nil ->
        {:error,
         Relay.Error.new(
           :template_producer_required,
           "producer templates are published with a platform product's credential"
         )}

      product ->
        {:ok, product}
    end
  end

  defp category(key) do
    case Relay.Preferences.category(key) do
      nil -> {:error, category_not_found()}
      %{"state" => "archived"} -> {:error, category_archived()}
      category -> {:ok, category}
    end
  end

  defp producer_inputs(at, t, category, body) do
    with :ok <- producer_owned(t, at),
         :ok <- definition_rules(body["definition"], true) do
      tenant = brand(at, nil)
      produced = body["definition"]["producer_brand"] || %{}

      {:ok,
       %{
         at: at,
         template: %{"message_class" => category["message_class"]},
         schemas: schemas(at.key),
         brand: producer_brand(produced, tenant),
         country: country()
       }}
    end
  end

  defp producer_owned(nil, _at), do: :ok
  defp producer_owned(%{"state" => "archived"}, _at), do: {:error, archived()}
  defp producer_owned(%{"owner_product" => product}, %{product: product}), do: :ok
  defp producer_owned(_t, _at), do: {:error, protected()}

  # TP-52
  defp producer_brand(produced, tenant) do
    Map.merge(produced, tenant, fn field, producer_value, tenant_value ->
      if field in @overridable, do: tenant_value, else: producer_value
    end)
  end

  defp producer_gate(inputs, body) do
    gate = run_gate(inputs, body["definition"])
    accept = body["accept_warnings"] == true

    with :ok <- Gate.outcome(gate.findings, accept, :template),
         do: {:ok, Map.merge(inputs, %{gate: gate, accept: accept})}
  end

  # TP-37
  # TP-52
  @doc "Creates the producer template on first use, otherwise writes a new draft, and publishes it at once inside the request's transaction; `200` with the new version."
  @spec producer_publish(Relay.Scope.t(), map(), map(), Relay.Actor.t()) :: answer()
  def producer_publish(scope, prepared, body, actor) do
    at = prepared.at

    with {:ok, expected} <- producer_write(scope, at, body, actor) do
      live =
        case TemplateStore.template(at.key, nil) do
          %{"live_version_no" => nil} -> nil
          t -> TemplateStore.template_version(t["id"], t["live_version_no"])
        end

      gate = %{
        variables: prepared.gate.variables,
        measures: prepared.gate.measures,
        findings: Enum.map(prepared.gate.findings, &Gate.view/1),
        accept_warnings: prepared.accept,
        diff: Gate.diff(live && definition(live), body["definition"])
      }

      digest = Gate.digest(scope, "template.published", at.key)

      case TemplateStore.template_publish(at, gate, expected, digest, actor) do
        {:published, _id, version_no, version} ->
          {:ok, {200, [etag(version)], published_view(at, version_no)}}

        {code, _id, _version_no, _version} ->
          {:error, publish_error(code, prepared.gate.findings)}
      end
    end
  end

  defp producer_write(scope, at, body, actor) do
    case TemplateStore.template(at.key, nil) do
      nil -> producer_create(scope, at, body, actor)
      t -> producer_redraft(scope, at, t, body, actor)
    end
  end

  defp producer_create(scope, at, body, actor) do
    attrs = %{
      id: Relay.Id.generate(),
      version_id: Relay.Id.generate(),
      key: at.key,
      subtenant_id: nil,
      product: at.product,
      name: body["name"],
      category: body["category"],
      definition: body["definition"]
    }

    digest = Gate.digest(scope, "template.created", at.key)

    case TemplateStore.template_create(attrs, digest, actor) do
      {:created, _id, _version_id, version} -> {:ok, version}
      {:category_not_found, _id, _version_id, _version} -> {:error, category_not_found()}
      {code, _id, _version_id, _version} -> {:error, create_error(code)}
    end
  end

  defp producer_redraft(scope, at, t, body, actor) do
    with :ok <- producer_owned(t, at),
         {:ok, expected} <- rename(scope, at, t, body, t["version"], actor) do
      digest = Gate.digest(scope, "template.drafted", at.key)
      definition = body["definition"]
      id = Relay.Id.generate()

      case TemplateStore.template_draft_put(at, id, definition, expected, digest, actor) do
        {result, _id, version} when result in [:created, :replaced, :unchanged] ->
          {:ok, version}

        {code, _id, _version} ->
          {:error, write_error(code)}
      end
    end
  end

  defp current(at) do
    t = TemplateStore.template(at.key, at.subtenant_id)
    view(t, TemplateStore.template_draft(t["id"]))
  end

  @doc "The template at a level inside the caller's scoped transaction."
  @spec found(at()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def found(at) do
    case TemplateStore.template(at.key, at.subtenant_id) do
      nil -> {:error, not_found()}
      t -> {:ok, t}
    end
  end

  defp owned(t, at) do
    if t["owner_product"] == at[:product], do: :ok, else: {:error, protected()}
  end

  defp active(%{"state" => "archived"}), do: {:error, archived()}
  defp active(_t), do: :ok

  defp draft(t) do
    case TemplateStore.template_draft(t["id"]) do
      nil -> {:error, no_draft()}
      draft -> {:ok, draft}
    end
  end

  defp numbered(t, number) do
    case TemplateStore.template_version(t["id"], number) do
      nil -> {:error, version_not_found()}
      v -> {:ok, v}
    end
  end

  @doc "The error of an unknown template key."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:template_not_found, "no template has this key")

  @doc "The error of an unknown template version."
  @spec version_not_found() :: Relay.Error.t()
  def version_not_found,
    do: Relay.Error.new(:template_version_not_found, "the template has no such version")

  defp archived, do: Relay.Error.new(:template_archived, "the template is archived")

  defp protected,
    do:
      Relay.Error.new(
        :template_protected,
        "the template belongs to a producer; only its brand fields can change"
      )

  defp no_draft, do: Relay.Error.new(:template_no_draft, "there is no draft to publish")

  defp draft_changed,
    do: Relay.Error.new(:template_draft_changed, "the draft changed; review it and publish again")

  defp precondition_failed,
    do: Relay.Error.new(:precondition_failed, "the template changed; read it again")

  defp category_not_found, do: Relay.Error.new(:category_not_found, "no category has this key")
  defp category_archived, do: Relay.Error.new(:category_archived, "the category is archived")
  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again")
end
