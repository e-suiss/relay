defmodule Relay.CLI.Remote do
  @moduledoc """
  The API side of the definition files: reading routes, templates and workflows of an environment and writing a file back, through the public operations only.

  * A route (`getRoute`, `createRoute`, `replaceRoute`) is unversioned: writing it changes it at once.
  * A template is written as its draft (`createTemplate`, `replaceTemplateDraft` with the template's ETag in `If-Match`) and, when asked, published (`publishTemplate` with the draft checksum, so a draft changed meanwhile is refused); the publication gate answers at once.
  * A workflow is written as its draft (`createWorkflow`, `replaceWorkflowDraft` under `If-Match`) and, when asked, sent to the publication gate (`publishWorkflow`, `202`); its result is read back from the workflow's `last_publication` and a rejection carries the gate's errors with their RFC 6901 pointers. A file is code, so a workflow the files create is made code-managed (`setWorkflowManager`, WF-4); a workflow managed from the panel is not overwritten unless the person asks for its manager to become code.

  A definition already equal to what the environment holds is left alone: no draft, no publication.
  """

  alias Relay.CLI.Client
  alias Relay.CLI.Context
  alias Relay.CLI.DefinitionFile
  alias Relay.CLI.Failure
  alias Relay.CLI.HTTP

  @poll_ms 1_000
  @default_polls 60
  @template_fields ["name", "category", "definition"]

  @type environment :: Relay.CLI.Config.environment()
  @type options :: %{
          publish: boolean(),
          note: String.t() | nil,
          accept_warnings: boolean(),
          manage_as_code: boolean()
        }

  # X-33
  # API-56
  @doc "The active tenant-level definitions of a kind in an environment, as the list operation returns them."
  @spec list(Context.t(), environment(), DefinitionFile.kind()) ::
          {:ok, [map()]} | {:error, Failure.t()}
  def list(ctx, environment, kind) do
    case Client.list_all(ctx, environment, collection(kind), limit: 100) do
      {:ok, items} -> {:ok, items |> Enum.filter(&listed?(kind, &1)) |> Enum.sort_by(& &1["key"])}
      {:error, _failure} = error -> error
    end
  end

  defp listed?(_kind, %{"state" => state}) when state != "active", do: false
  defp listed?(:template, %{"protected" => true}), do: false
  defp listed?(:template, %{"subtenant" => subtenant}) when subtenant != nil, do: false
  defp listed?(_kind, item), do: DefinitionFile.safe_key?(item["key"])

  # X-33
  @doc "The file body of a listed definition: a workflow's or template's draft, otherwise its published version; a route as it is. `nil` when there is neither."
  @spec pulled(Context.t(), environment(), DefinitionFile.kind(), map()) ::
          {:ok, map() | nil, String.t()} | {:error, Failure.t()}
  def pulled(_ctx, _environment, :route, route), do: {:ok, route_body(route), "route"}

  def pulled(_ctx, _environment, :template, %{"draft" => %{} = draft} = template),
    do: {:ok, template_body(template, draft), "draft"}

  def pulled(ctx, environment, :template, %{"live_version" => version} = template)
      when is_integer(version) do
    path = version_path(:template, template["key"], version)

    with {:ok, v} <- get_body(ctx, environment, path) do
      {:ok, template_body(template, v["definition"]), "version #{version}"}
    end
  end

  def pulled(_ctx, _environment, :workflow, %{"draft" => %{} = draft} = workflow),
    do: {:ok, workflow_body(workflow["key"], draft), "draft"}

  def pulled(ctx, environment, :workflow, %{"published_version" => version} = workflow)
      when is_integer(version) do
    with {:ok, definition} <- workflow_version(ctx, environment, workflow["key"], version) do
      {:ok, workflow_body(workflow["key"], definition), "version #{version}"}
    end
  end

  def pulled(_ctx, _environment, _kind, _item), do: {:ok, nil, "none"}

  # WF-6
  @doc "The published body of a definition and its version, for promotion: a route as it is (unversioned), a template's live version or a workflow's published version, or the given version."
  @spec published(
          Context.t(),
          environment(),
          DefinitionFile.kind(),
          String.t(),
          pos_integer() | nil
        ) :: {:ok, map(), pos_integer() | nil} | {:error, Failure.t()}
  def published(ctx, environment, :route, key, nil) do
    case get(ctx, environment, path(:route, key)) do
      {:ok, %{"state" => "active"} = route, _etag} -> {:ok, route_body(route), nil}
      {:ok, _archived, _etag} -> invalid("route_archived", "route #{key} is archived in test")
      {:error, _failure} = error -> error
    end
  end

  def published(_ctx, _environment, :route, _key, _version),
    do: {:error, Failure.new(:usage, "usage_error", "a route has no versions; drop --version")}

  def published(ctx, environment, :template, key, version) do
    with {:ok, template, _etag} <- get(ctx, environment, path(:template, key)),
         {:ok, number} <- source_version(template["live_version"], version, :template, key),
         {:ok, v} <- get_body(ctx, environment, version_path(:template, key, number)) do
      {:ok, template_body(template, v["definition"]), number}
    end
  end

  def published(ctx, environment, :workflow, key, version) do
    with {:ok, workflow, _etag} <- get(ctx, environment, path(:workflow, key)),
         {:ok, number} <- source_version(workflow["published_version"], version, :workflow, key),
         {:ok, definition} <- workflow_version(ctx, environment, key, number) do
      {:ok, workflow_body(key, definition), number}
    end
  end

  defp source_version(_current, version, _kind, _key) when is_integer(version) and version >= 1,
    do: {:ok, version}

  defp source_version(_current, version, _kind, _key) when is_integer(version),
    do: {:error, Failure.new(:usage, "usage_error", "--version is a version number from 1")}

  defp source_version(current, nil, _kind, _key) when is_integer(current), do: {:ok, current}

  defp source_version(nil, nil, kind, key) do
    name = DefinitionFile.name(kind)
    invalid("#{name}_not_published", "#{name} #{key} has no published version in test")
  end

  # X-33
  # WF-4
  # WF-6
  @doc "Writes one definition file to an environment and, when asked, publishes it; returns what was done."
  @spec push(Context.t(), environment(), DefinitionFile.t(), options()) ::
          {:ok, map()} | {:error, Failure.t()}
  def push(ctx, environment, %{kind: kind, key: key} = file, opts) do
    result =
      case kind do
        :route -> push_route(ctx, environment, file)
        :template -> push_template(ctx, environment, file, opts)
        :workflow -> push_workflow(ctx, environment, file, opts)
      end

    case result do
      {:ok, {draft, publication}} ->
        {:ok,
         %{
           "kind" => DefinitionFile.name(kind),
           "key" => key,
           "file" => file.path,
           "result" => draft,
           "publication" => publication
         }}

      {:error, %Failure{} = failure} ->
        {:error, %{failure | message: "#{DefinitionFile.name(kind)} #{key}: #{failure.message}"}}
    end
  end

  defp push_route(ctx, environment, %{key: key, body: body}) do
    case get(ctx, environment, path(:route, key)) do
      {:ok, route, etag} ->
        if Map.take(route, ["name", "tree"]) == Map.take(body, ["name", "tree"]),
          do: {:ok, {"unchanged", nil}},
          else: replace_route(ctx, environment, key, body, etag)

      {:error, %Failure{status: 404}} ->
        with {:ok, _response} <- post(ctx, environment, "/v1/routes", body, nil),
             do: {:ok, {"created", nil}}

      {:error, _failure} = error ->
        error
    end
  end

  defp replace_route(ctx, environment, key, body, etag) do
    replace = Map.take(body, ["name", "tree"])

    with {:ok, _response} <- put(ctx, environment, path(:route, key), replace, etag),
         do: {:ok, {"updated", nil}}
  end

  defp push_template(ctx, environment, %{key: key, body: body}, opts) do
    with {:ok, draft, template, etag} <- template_draft(ctx, environment, key, body),
         {:ok, publication} <- template_publish(ctx, environment, key, template, etag, opts),
         do: {:ok, {draft, publication}}
  end

  defp template_draft(ctx, environment, key, body) do
    case get(ctx, environment, path(:template, key)) do
      {:ok, template, etag} ->
        if template_fields(template) == Map.take(body, @template_fields),
          do: {:ok, "unchanged", template, etag},
          else: replace_template(ctx, environment, key, body, etag)

      {:error, %Failure{status: 404}} ->
        with {:ok, response} <- post(ctx, environment, "/v1/templates", body, nil),
             do: {:ok, "created", response.body, HTTP.header(response, "etag")}

      {:error, _failure} = error ->
        error
    end
  end

  defp template_fields(template) do
    template
    |> Map.take(["name", "category"])
    |> Map.put("definition", template["draft"])
  end

  defp replace_template(ctx, environment, key, body, etag) do
    replace = Map.take(body, @template_fields)

    with {:ok, response} <- put(ctx, environment, path(:template, key), replace, etag),
         do: {:ok, "updated", response.body, HTTP.header(response, "etag")}
  end

  # TP-31
  defp template_publish(_ctx, _environment, _key, _template, _etag, %{publish: false}),
    do: {:ok, nil}

  defp template_publish(ctx, environment, key, template, etag, opts) do
    if live?(ctx, environment, key, template) do
      {:ok, %{"status" => "current", "version" => template["live_version"]}}
    else
      body =
        %{"accept_warnings" => opts.accept_warnings}
        |> put_present("checksum", template["draft_checksum"])
        |> put_present("note", opts.note)

      case post(ctx, environment, path(:template, key) <> "/publish", body, etag) do
        {:ok, %{body: %{"version" => version}}} ->
          {:ok, %{"status" => "published", "version" => version}}

        {:ok, _response} ->
          {:error, Client.unexpected_body()}

        {:error, %Failure{status: 409, code: "template_version_duplicate"}} ->
          {:ok, %{"status" => "current", "version" => template["live_version"]}}

        {:error, _failure} = error ->
          error
      end
    end
  end

  defp live?(ctx, environment, key, %{"live_version" => version, "draft_checksum" => checksum})
       when is_integer(version) and is_binary(checksum) do
    case get_body(ctx, environment, version_path(:template, key, version)) do
      {:ok, %{"checksum" => ^checksum}} -> true
      _other -> false
    end
  end

  defp live?(_ctx, _environment, _key, _template), do: false

  defp push_workflow(ctx, environment, %{key: key, body: %{"definition" => definition}}, opts) do
    with {:ok, draft, workflow, etag} <-
           workflow_draft(ctx, environment, key, definition, opts) do
      cond do
        not opts.publish -> {:ok, {draft, nil}}
        draft == "current" -> {:ok, {"unchanged", current(workflow)}}
        true -> publish_workflow(ctx, environment, key, etag, opts, draft)
      end
    end
  end

  defp current(workflow), do: %{"status" => "current", "version" => workflow["published_version"]}

  defp workflow_draft(ctx, environment, key, definition, opts) do
    case get(ctx, environment, path(:workflow, key)) do
      {:ok, workflow, etag} ->
        with {:ok, workflow, etag} <- manager(ctx, environment, key, workflow, etag, opts),
             do: redraft(ctx, environment, key, definition, workflow, etag)

      {:error, %Failure{status: 404}} ->
        body = workflow_body(key, definition)

        with {:ok, response} <- post(ctx, environment, "/v1/workflows", body, nil),
             {:ok, workflow, etag} <-
               set_manager(ctx, environment, key, HTTP.header(response, "etag")),
             do: {:ok, "created", workflow, etag}

      {:error, _failure} = error ->
        error
    end
  end

  # WF-4
  # X-9
  defp manager(_ctx, _environment, _key, %{"managed_by" => "code"} = workflow, etag, _opts),
    do: {:ok, workflow, etag}

  defp manager(ctx, environment, key, _workflow, etag, %{manage_as_code: true}),
    do: set_manager(ctx, environment, key, etag)

  defp manager(_ctx, _environment, key, _workflow, _etag, _opts) do
    invalid(
      "workflow_managed_by_panel",
      "#{key} is managed from the panel; pass --manage-as-code to make code its single manager"
    )
  end

  defp set_manager(ctx, environment, key, etag) do
    body = %{"managed_by" => "code"}

    case post(ctx, environment, path(:workflow, key) <> "/manager", body, etag) do
      {:ok, %{body: %{"key" => _key} = workflow} = response} ->
        {:ok, workflow, HTTP.header(response, "etag")}

      {:ok, _response} ->
        {:error, Client.unexpected_body()}

      {:error, _failure} = error ->
        error
    end
  end

  defp redraft(ctx, environment, key, definition, workflow, etag) do
    cond do
      same?(workflow["draft"], definition) ->
        {:ok, "unchanged", workflow, etag}

      workflow["draft"] == nil and published?(ctx, environment, key, workflow, definition) ->
        {:ok, "current", workflow, etag}

      true ->
        opts = %{"definition" => definition}

        with {:ok, response} <- put(ctx, environment, path(:workflow, key), opts, etag),
             do: {:ok, "updated", workflow, HTTP.header(response, "etag")}
    end
  end

  defp published?(ctx, environment, key, %{"published_version" => version}, definition)
       when is_integer(version) do
    case workflow_version(ctx, environment, key, version) do
      {:ok, published} -> same?(published, definition)
      {:error, _failure} -> false
    end
  end

  defp published?(_ctx, _environment, _key, _workflow, _definition), do: false

  # PC-57 (3)
  defp same?(%{} = stored, %{} = definition) when not is_map_key(definition, "message_class"),
    do: Map.delete(stored, "message_class") == definition

  defp same?(stored, definition), do: stored == definition

  defp publish_workflow(ctx, environment, key, etag, opts, draft) do
    body = put_present(%{}, "note", opts.note)

    case post(ctx, environment, path(:workflow, key) <> "/publish", body, etag) do
      {:ok, %{body: %{"publication" => %{} = publication}}} ->
        await(ctx, environment, key, publication, draft, polls(ctx))

      {:ok, _response} ->
        {:error, Client.unexpected_body()}

      {:error, _failure} = error ->
        error
    end
  end

  # WF-6
  defp await(ctx, environment, key, %{"status" => "pending"} = publication, draft, polls)
       when polls > 0 do
    case get(ctx, environment, path(:workflow, key)) do
      {:ok, %{"last_publication" => %{"status" => "pending"}}, _etag} ->
        ctx.sleep.(@poll_ms)
        await(ctx, environment, key, publication, draft, polls - 1)

      {:ok, %{"last_publication" => %{} = latest}, _etag} ->
        await(ctx, environment, key, latest, draft, 0)

      {:ok, _workflow, _etag} ->
        {:ok, {draft, publication}}

      {:error, _failure} = error ->
        error
    end
  end

  defp await(_ctx, _environment, key, %{"status" => "rejected"} = publication, _draft, _polls) do
    errors = Map.get(publication, "errors", [])
    message = "the publication gate rejected #{key} with #{length(errors)} error(s)"
    failure = Failure.new(:invalid, "workflow_publication_rejected", message)
    {:error, %{failure | response: %{"errors" => errors, "publication" => publication}}}
  end

  defp await(_ctx, _environment, _key, publication, draft, _polls),
    do: {:ok, {draft, publication}}

  defp polls(%Context{max_polls: polls}) when is_integer(polls), do: polls
  defp polls(_ctx), do: @default_polls

  defp workflow_version(ctx, environment, key, version) do
    case get_body(ctx, environment, version_path(:workflow, key, version)) do
      {:ok, %{"definition" => %{} = definition}} -> {:ok, definition}
      {:ok, _body} -> {:error, Client.unexpected_body()}
      {:error, _failure} = error -> error
    end
  end

  defp route_body(route), do: Map.take(route, ["key", "name", "tree"])

  defp template_body(template, definition) do
    template
    |> Map.take(["key", "name", "category"])
    |> Map.put("definition", definition)
  end

  defp workflow_body(key, definition), do: %{"key" => key, "definition" => definition}

  defp get(ctx, environment, path) do
    case Client.call(ctx, environment, :get, path) do
      {:ok, %{body: %{"key" => _key} = body} = response} ->
        {:ok, body, HTTP.header(response, "etag")}

      {:ok, _response} ->
        {:error, Client.unexpected_body()}

      {:error, _failure} = error ->
        error
    end
  end

  defp get_body(ctx, environment, path) do
    case Client.call(ctx, environment, :get, path) do
      {:ok, %{body: %{} = body}} -> {:ok, body}
      {:ok, _response} -> {:error, Client.unexpected_body()}
      {:error, _failure} = error -> error
    end
  end

  defp put(ctx, environment, path, body, etag),
    do: Client.call(ctx, environment, :put, path, json: body, headers: if_match(etag))

  defp post(ctx, environment, path, body, etag),
    do: Client.call(ctx, environment, :post, path, json: body, headers: if_match(etag))

  defp if_match(nil), do: []
  defp if_match(etag), do: [{"if-match", etag}]

  defp collection(:route), do: "/v1/routes"
  defp collection(:template), do: "/v1/templates"
  defp collection(:workflow), do: "/v1/workflows"

  defp path(kind, key), do: collection(kind) <> "/" <> Client.segment(key)

  defp version_path(kind, key, version),
    do: path(kind, key) <> "/versions/" <> Client.segment(version)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp invalid(code, message), do: {:error, Failure.new(:invalid, code, message)}
end
