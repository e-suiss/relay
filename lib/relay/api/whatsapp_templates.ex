defmodule Relay.Api.WhatsappTemplates do
  @moduledoc """
  The WhatsApp template operations of the server API (`/v1/whatsapp/templates`, CH-57, TP-23). A registration maps a Meta template, by its name and language on a WhatsApp provider account, to a Relay message class, whose fixed WhatsApp category it takes; it starts `pending_approval` and only Meta's approval makes it sendable. A template is immutable: the same name and language with other content is `409 resource_conflict`, and new content is a new name. An answer shows the Relay state next to Meta's status and category, Meta's rejection reason, the text Meta approved with the placeholders (`preview`), the category drift and the edits left.
  """

  alias Relay.Api.Page
  alias Relay.Api.Views

  @limits "whatsapp_messaging_limits"

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # CH-57
  # TP-23
  @doc "The API view of a WhatsApp template row."
  @spec view(map()) :: map()
  def view(t) do
    derived = Relay.Channels.whatsapp_template_view(t, [], edit_limits(), Relay.Clock.utc_now())

    %{
      "object" => "whatsapp_template",
      "id" => Views.id("wtp", t["id"]),
      "provider_account_id" => Relay.Id.to_string(t["provider_account_id"]),
      "waba_id" => t["waba_id"],
      "name" => t["name"],
      "language" => t["language"],
      "message_class" => t["message_class"],
      "category" => t["category"],
      "meta_category" => t["meta_category"],
      "status" => t["status"],
      "meta_status" => t["meta_status"],
      "meta_template_id" => t["meta_template_id"],
      "rejection_reason" => t["rejection_reason"],
      "quality" => t["quality"],
      "sendable" => derived.sendable,
      "components" => t["components"],
      "approved_components" => t["approved_components"],
      "preview" => preview(derived.preview),
      "category_drift" => drift(derived.drift),
      "edit_quota" => quota(derived.edit_quota),
      "status_changed_at" => t["status_changed_at"],
      "version" => t["version"],
      "created_at" => t["created_at"],
      "updated_at" => t["updated_at"]
    }
  end

  defp preview(p) do
    %{
      "header" => p.header,
      "body" => p.body,
      "footer" => p.footer,
      "placeholders" => p.missing
    }
  end

  defp drift(:none), do: nil

  defp drift({:drift, d}),
    do: %{"expected" => d.expected, "actual" => d.actual, "cost_increase" => d.cost_up?}

  defp quota(q) do
    %{
      "remaining" => q.remaining,
      "next_at" => q.next_at,
      "reason" => q.reason && Atom.to_string(q.reason)
    }
  end

  defp edit_limits do
    content =
      case Relay.Datasets.active(Relay.Datasets.installation_scope(), @limits) do
        {:ok, %{content: %{} = content}} -> content
        _none -> Relay.Channels.whatsapp_bundled(@limits)
      end

    content["template_edits"]
  end

  # CH-57
  # TP-23
  @doc "Prepares a registration outside any transaction: the body is mapped to the row the template is written with."
  @spec prepare(map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def prepare(body) do
    attrs = %{
      provider_account_id: body["provider_account_id"],
      waba_id: body["waba_id"],
      name: body["name"],
      language: body["language"],
      message_class: body["message_class"],
      components: body["components"]
    }

    with {:ok, account_id} <- account_id(attrs.provider_account_id),
         attrs = %{attrs | provider_account_id: account_id},
         {:ok, row} <- Relay.Channels.whatsapp_template_row(attrs) do
      {:ok, row}
    else
      {:error, :pointer, pointer} -> field(pointer, "invalid_format", "the value is not valid")
      {:error, :unknown_class} -> field("/message_class", "unsupported_value", "unknown class")
      {:error, :invalid_content} -> field("/language", "invalid_format", "not a language")
    end
  end

  defp account_id(value) do
    case Relay.Id.parse(value) do
      {:ok, id} -> {:ok, id}
      {:error, _error} -> {:error, :pointer, "/provider_account_id"}
    end
  end

  # CH-57
  @doc "Registers a prepared template inside the request's transaction: `201` when created, `200` when it is already registered with the same content."
  @spec register(map()) :: answer()
  def register(row) do
    case Relay.Channels.insert_whatsapp_template(row) do
      {:created, id} -> {:ok, {201, [], template(id)}}
      {:exists, id} -> {:ok, {200, [], template(id)}}
      {:content_conflict, _id} -> {:error, conflict()}
      {:account_not_found, _id} -> {:error, not_configured()}
    end
  end

  # API-56
  @doc "Lists the WhatsApp templates newest first, in pages."
  @spec list(Relay.Scope.t(), Relay.Api.Pagination.page(), String.t()) :: answer()
  def list(scope, page, endpoint) do
    case Relay.Channels.whatsapp_templates(scope, page.cursor, page.limit) do
      {:ok, rows} ->
        position = &{&1["created_at"], &1["id"]}

        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &view/1, position),
             do: {:ok, {200, [], body}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # CH-57
  @doc "Reads a WhatsApp template."
  @spec get(Relay.Scope.t(), Relay.Id.t()) :: answer()
  def get(scope, id) do
    case Relay.Channels.get_whatsapp_template(scope, id) do
      {:ok, %{} = row} -> {:ok, {200, [], view(row)}}
      {:ok, nil} -> {:error, not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp template(id), do: id |> Relay.Channels.whatsapp_template() |> view()

  defp field(pointer, code, detail) do
    {:error,
     Relay.Error.new(:validation_failed, detail, %{
       errors: [%{pointer: pointer, code: code, detail: detail}]
     })}
  end

  @doc "The error of an unknown WhatsApp template."
  @spec not_found() :: Relay.Error.t()
  def not_found,
    do: Relay.Error.new(:whatsapp_template_not_found, "no WhatsApp template has this id")

  defp conflict do
    message = "a template with this name and language is registered with other content"
    Relay.Error.new(:resource_conflict, message)
  end

  defp not_configured do
    message = "the provider account is not an active WhatsApp account of this tenant"
    Relay.Error.new(:channel_not_configured, message)
  end

  defp unavailable do
    Relay.Error.new(:service_unavailable, "the WhatsApp templates could not be read", %{
      retry_after: 1
    })
  end
end
