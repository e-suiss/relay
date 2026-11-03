defmodule Relay.Api.TemplateAssets do
  @moduledoc """
  Layout and partial management on the server API (API-69, TP-31, TP-35, TP-48): list, create with a first draft (`201`), read, replace the draft under `If-Match`, publish through the publication gate (a layout's MJML compiles and declares its icons; a partial's bodies parse in supported locales with complete ICU forms), archive (refused while a live template version uses it), list and read versions, and promote an old version back to live after revalidating it. `kind` is `:layout` or `:partial`; the gate runs before the write transaction (TP-8).
  """

  alias Relay.Api.Gate
  alias Relay.Api.Page
  alias Relay.Api.Pagination
  alias Relay.Api.Views
  alias Relay.TemplateStore

  @type kind :: :layout | :partial
  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}
  @type at :: %{key: String.t(), subtenant_id: Relay.Id.t() | nil}

  @prefixes %{layout: {"lay", "lyv"}, partial: {"prt", "ptv"}}

  # TP-35
  @doc "The API view of a layout or partial row and its draft row."
  @spec view(kind(), map(), map() | nil) :: map()
  def view(kind, a, draft) do
    {prefix, _version_prefix} = @prefixes[kind]

    %{
      "object" => Atom.to_string(kind),
      "id" => Views.id(prefix, a["id"]),
      "key" => a["key"],
      "name" => a["name"],
      "owner" => a["owner"],
      "subtenant" => Views.id("stn", a["subtenant_id"]),
      "state" => a["state"],
      "live_version" => a["live_version_no"],
      "draft" => draft && draft["content"],
      "version" => a["version"],
      "created_at" => a["created_at"],
      "updated_at" => a["updated_at"]
    }
  end

  # TP-31
  @doc "The API view of a published or archived layout or partial version."
  @spec version_view(kind(), String.t(), map(), Relay.Id.t() | nil) :: map()
  def version_view(kind, key, v, live_id) do
    {_prefix, version_prefix} = @prefixes[kind]

    %{
      "object" => "#{kind}_version",
      "id" => Views.id(version_prefix, v["id"]),
      "#{kind}_key" => key,
      "version" => v["version_no"],
      "state" => v["state"],
      "live" => v["id"] == live_id,
      "definition" => v["content"],
      "checksum" => Gate.hex(v["checksum"]),
      "findings" => v["findings"] || [],
      "warnings_accepted" => v["warnings_accepted"],
      "previous_version" => v["previous_version_no"],
      "diff" => v["diff"],
      "published_at" => v["published_at"],
      "published_by" => v["published_by_ref"]
    }
  end

  @doc "The ETag header of a resource version number."
  @spec etag(pos_integer()) :: {String.t(), String.t()}
  def etag(version), do: {"etag", ~s("#{version}")}

  # TP-35
  # TP-48
  @doc "Creates a layout or partial with its first draft inside the request's transaction; `201` with its view."
  @spec create(kind(), Relay.Scope.t(), Relay.Id.t() | nil, map(), Relay.Actor.t()) :: answer()
  def create(kind, scope, subtenant_id, body, actor) do
    with :ok <- locales(kind, body["definition"]) do
      attrs = %{
        id: Relay.Id.generate(),
        version_id: Relay.Id.generate(),
        key: body["key"],
        subtenant_id: subtenant_id,
        name: body["name"],
        content: body["definition"]
      }

      digest = Gate.digest(scope, "#{kind}.created", body["key"])

      case TemplateStore.asset_create(kind, attrs, digest, actor) do
        {:created, _id, _version_id, version} ->
          at = %{key: body["key"], subtenant_id: subtenant_id}
          location = {"location", "/v1/#{kind}s/" <> body["key"]}
          {:ok, {201, [etag(version), location], current(kind, at)}}

        {:key_conflict, _id, _version_id, _version} ->
          {:error, Relay.Error.new(:resource_conflict, "a #{kind} with this key exists")}

        {:subtenant_not_found, _id, _version_id, _version} ->
          {:error, Gate.field_error("/subtenant", "not_found", "no subtenant has this id")}

        {:tenant_inactive, _id, _version_id, _version} ->
          {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}
      end
    end
  end

  # TP-56
  defp locales(:partial, definition) do
    locales = [definition["default_locale"] | Map.keys(definition["bodies"] || %{})]

    if Enum.all?(locales, &Relay.Templates.locale_supported?/1),
      do: :ok,
      else: {:error, Gate.field_error("/definition", "unsupported_value", "unsupported locale")}
  end

  defp locales(:layout, _definition), do: :ok

  # TP-35
  @doc "Replaces the draft and the name of a layout or partial inside the request's transaction."
  @spec replace(kind(), Relay.Scope.t(), at(), map(), pos_integer(), Relay.Actor.t()) :: answer()
  def replace(kind, scope, at, body, expected, actor) do
    with {:ok, a} <- found(kind, at),
         :ok <- locales(kind, body["definition"]) do
      attrs = %{name: Map.get(body, "name", a["name"]), content: body["definition"]}
      digest = Gate.digest(scope, "#{kind}.drafted", at.key)
      id = Relay.Id.generate()

      case TemplateStore.asset_draft_put(kind, at, id, attrs, expected, digest, actor) do
        {result, _id, version} when result in [:created, :replaced, :unchanged] ->
          {:ok, {200, [etag(version)], current(kind, at)}}

        {code, _id, _version} ->
          {:error, error(kind, code)}
      end
    end
  end

  # TP-31
  # TP-32
  @doc "Prepares a publication outside any transaction: reads the draft and runs the publication gate over it. The result is handed to `publish/6`."
  @spec prepare_publish(kind(), Relay.Scope.t(), at(), map() | nil) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def prepare_publish(kind, scope, at, body) do
    read =
      TemplateStore.in_scope(scope, fn _status ->
        with {:ok, a} <- found(kind, at),
             :ok <- active(kind, a),
             {:ok, draft} <- draft(kind, a) do
          {:ok, %{asset: a, draft: draft, live: live(kind, a)}}
        end
      end)

    with {:ok, {:ok, inputs}} <- read,
         :ok <- reviewed(body, inputs.draft) do
      findings = gate(kind, inputs.draft["content"])
      accept = Map.get(body || %{}, "accept_warnings", false) == true

      with :ok <- Gate.outcome(findings, accept, :asset),
           do: {:ok, Map.merge(inputs, %{findings: findings, accept: accept})}
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

  defp live(_kind, %{"live_version_no" => nil}), do: nil
  defp live(kind, a), do: TemplateStore.asset_version(kind, a["id"], a["live_version_no"])

  defp gate(:layout, content),
    do: Relay.Templates.layout_gate(content, compile: &Relay.Templates.compile_mjml/1).findings

  defp gate(:partial, content), do: Relay.Templates.partial_gate(content).findings

  # TP-31
  # TP-35
  @doc "Publishes the draft a prepared gate ran on inside the request's transaction; `200` with the new version."
  @spec publish(kind(), Relay.Scope.t(), at(), map(), pos_integer(), Relay.Actor.t()) :: answer()
  def publish(kind, scope, at, prepared, expected, actor) do
    live = prepared.live && prepared.live["content"]

    gate = %{
      findings: Enum.map(prepared.findings, &Gate.view/1),
      accept_warnings: prepared.accept,
      checksum: prepared.draft["checksum"],
      diff: diff(live, prepared.draft["content"])
    }

    digest = Gate.digest(scope, "#{kind}.published", at.key)

    case TemplateStore.asset_publish(kind, at, gate, expected, digest, actor) do
      {:published, _id, version_no, version} ->
        a = TemplateStore.asset(kind, at.key, at.subtenant_id)
        v = TemplateStore.asset_version(kind, a["id"], version_no)
        {:ok, {200, [etag(version)], version_view(kind, at.key, v, a["live_version_id"])}}

      {code, _id, _version_no, _version} ->
        {:error, publish_error(kind, code, prepared.findings)}
    end
  end

  defp diff(nil, _content), do: nil

  defp diff(live, content) do
    keys = Map.keys(Map.merge(live, content))
    %{"fields" => for(key <- Enum.sort(keys), live[key] != content[key], do: key)}
  end

  defp publish_error(_kind, :no_draft, _findings),
    do: Relay.Error.new(:template_no_draft, "there is no draft to publish")

  defp publish_error(_kind, :draft_changed, _findings), do: draft_changed()
  defp publish_error(_kind, :gate_failed, findings), do: Gate.gate_failed(findings)

  defp publish_error(_kind, :warnings_unaccepted, findings) do
    {:error, error} = Gate.outcome(findings, false, :asset)
    error
  end

  defp publish_error(kind, :duplicate, _findings),
    do:
      Relay.Error.new(
        :template_version_duplicate,
        "the draft is identical to a published #{kind} version; promote that version instead"
      )

  defp publish_error(kind, code, _findings), do: error(kind, code)

  # TP-31
  @doc "Prepares a promotion outside any transaction: reads the version and revalidates it through the publication gate; only a hard finding refuses it."
  @spec prepare_promote(kind(), Relay.Scope.t(), at(), pos_integer()) ::
          :ok | {:error, Relay.Error.t()}
  def prepare_promote(kind, scope, at, number) do
    read =
      TemplateStore.in_scope(scope, fn _status ->
        with {:ok, a} <- found(kind, at), do: numbered(kind, a, number)
      end)

    case read do
      {:ok, {:ok, v}} ->
        hard = kind |> gate(v["content"]) |> Enum.filter(&(&1.level == :hard))
        if hard == [], do: :ok, else: {:error, Gate.gate_failed(hard)}

      {:ok, {:error, error}} ->
        {:error, error}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # TP-31
  @doc "Moves the live pointer of a layout or partial back to a revalidated version inside the request's transaction."
  @spec promote(kind(), Relay.Scope.t(), at(), pos_integer(), pos_integer(), Relay.Actor.t()) ::
          answer()
  def promote(kind, scope, at, number, expected, actor) do
    digest = Gate.digest(scope, "#{kind}.rolled_back", at.key)

    case TemplateStore.asset_rollback(kind, at, number, expected, digest, actor) do
      {result, _id, version} when result in [:rolled_back, :unchanged] ->
        {:ok, {200, [etag(version)], current(kind, at)}}

      {:version_not_found, _id, _version} ->
        {:error, version_not_found(kind)}

      {:version_archived, _id, _version} ->
        {:error, Relay.Error.new(:template_version_archived, "the version is archived")}

      {code, _id, _version} ->
        {:error, error(kind, code)}
    end
  end

  # TP-48
  @doc "Archives a layout or partial inside the request's transaction; one a live template version uses is refused."
  @spec archive(kind(), Relay.Scope.t(), at(), pos_integer(), Relay.Actor.t()) :: answer()
  def archive(kind, scope, at, expected, actor) do
    digest = Gate.digest(scope, "#{kind}.archived", at.key)

    case TemplateStore.asset_archive(kind, at, expected, digest, actor) do
      {result, version} when result in [:archived, :already_archived] ->
        {:ok, {200, [etag(version)], current(kind, at)}}

      {code, _version} ->
        {:error, error(kind, code)}
    end
  end

  # API-56
  @doc "Lists the layouts or partials of a level."
  @spec list(kind(), Relay.Scope.t(), Relay.Id.t() | nil, Pagination.page(), String.t()) ::
          answer()
  def list(kind, scope, subtenant_id, page, endpoint) do
    read =
      TemplateStore.in_scope(scope, fn _status ->
        for a <- TemplateStore.asset_page(kind, subtenant_id, page.cursor, page.limit),
            do: Map.put(a, "draft", TemplateStore.asset_draft(kind, a["id"]))
      end)

    case read do
      {:ok, rows} ->
        position = &{&1["cursor_at"], &1["id"]}
        view = &view(kind, &1, &1["draft"])

        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, view, position),
             do: {:ok, {200, [], body}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  @doc "Reads a layout or partial."
  @spec get(kind(), Relay.Scope.t(), at()) :: answer()
  def get(kind, scope, at) do
    read =
      TemplateStore.in_scope(scope, fn _status ->
        with {:ok, a} <- found(kind, at), do: {:ok, a, TemplateStore.asset_draft(kind, a["id"])}
      end)

    case read do
      {:ok, {:ok, a, draft}} -> {:ok, {200, [etag(a["version"])], view(kind, a, draft)}}
      {:ok, {:error, error}} -> {:error, error}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # API-56
  @doc "Lists the published and archived versions of a layout or partial."
  @spec versions(kind(), Relay.Scope.t(), at(), Pagination.page(), String.t()) :: answer()
  def versions(kind, scope, at, page, endpoint) do
    read =
      TemplateStore.in_scope(scope, fn _status ->
        with {:ok, a} <- found(kind, at) do
          {:ok, a, TemplateStore.asset_version_page(kind, a["id"], page.cursor, page.limit)}
        end
      end)

    case read do
      {:ok, {:ok, a, rows}} ->
        position = &{&1["cursor_at"], &1["id"]}
        view = &version_view(kind, at.key, &1, a["live_version_id"])

        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, view, position),
             do: {:ok, {200, [], body}}

      {:ok, {:error, error}} ->
        {:error, error}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  @doc "Reads one published or archived version of a layout or partial."
  @spec version(kind(), Relay.Scope.t(), at(), pos_integer()) :: answer()
  def version(kind, scope, at, number) do
    read =
      TemplateStore.in_scope(scope, fn _status ->
        with {:ok, a} <- found(kind, at),
             {:ok, v} <- numbered(kind, a, number),
             do: {:ok, version_view(kind, at.key, v, a["live_version_id"])}
      end)

    case read do
      {:ok, {:ok, view}} -> {:ok, {200, [], view}}
      {:ok, {:error, error}} -> {:error, error}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp current(kind, at) do
    a = TemplateStore.asset(kind, at.key, at.subtenant_id)
    view(kind, a, TemplateStore.asset_draft(kind, a["id"]))
  end

  defp found(kind, at) do
    case TemplateStore.asset(kind, at.key, at.subtenant_id) do
      nil -> {:error, not_found(kind)}
      a -> {:ok, a}
    end
  end

  defp active(kind, %{"state" => "archived"}), do: {:error, error(kind, :archived)}
  defp active(_kind, _a), do: :ok

  defp draft(kind, a) do
    case TemplateStore.asset_draft(kind, a["id"]) do
      nil -> {:error, Relay.Error.new(:template_no_draft, "there is no draft to publish")}
      draft -> {:ok, draft}
    end
  end

  defp numbered(kind, a, number) do
    case TemplateStore.asset_version(kind, a["id"], number) do
      nil -> {:error, version_not_found(kind)}
      v -> {:ok, v}
    end
  end

  defp error(kind, :not_found), do: not_found(kind)
  defp error(:layout, :archived), do: Relay.Error.new(:layout_archived, "the layout is archived")

  defp error(:partial, :archived),
    do: Relay.Error.new(:partial_archived, "the partial is archived")

  defp error(:layout, :in_use),
    do: Relay.Error.new(:layout_in_use, "a live template version uses the layout")

  defp error(:partial, :in_use),
    do: Relay.Error.new(:partial_in_use, "a live template version uses the partial")

  defp error(kind, :version_conflict),
    do: Relay.Error.new(:precondition_failed, "the #{kind} changed; read it again")

  @doc "The error of an unknown layout or partial key."
  @spec not_found(kind()) :: Relay.Error.t()
  def not_found(:layout), do: Relay.Error.new(:layout_not_found, "no layout has this key")
  def not_found(:partial), do: Relay.Error.new(:partial_not_found, "no partial has this key")

  @doc "The error of an unknown layout or partial version."
  @spec version_not_found(kind()) :: Relay.Error.t()
  def version_not_found(:layout),
    do: Relay.Error.new(:layout_version_not_found, "the layout has no such version")

  def version_not_found(:partial),
    do: Relay.Error.new(:partial_version_not_found, "the partial has no such version")

  defp draft_changed,
    do: Relay.Error.new(:template_draft_changed, "the draft changed; review it and publish again")

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again")
end
