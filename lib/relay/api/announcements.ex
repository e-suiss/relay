defmodule Relay.Api.Announcements do
  @moduledoc """
  The inbox announcements of the server API (IN-3, C-70, API-35): a tenant publishes one announcement record for its whole environment, for a sub-tenant or for the subscribers of a topic, reads it and retracts it. No row is written per recipient; every recipient in the audience sees it merged into its inbox at read time, counted in its counters and in its delta. The content is rendered by the sender and checked against the published inbox limits (IN-49). Creation and retraction are audited.
  """

  alias Relay.Scope

  @audiences ~w(tenant subtenant topic)

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # IN-3
  # API-35
  # IN-49
  @doc "Publishes an announcement inside the request's transaction."
  @spec create(Scope.t(), map(), Relay.Actor.t()) :: answer()
  def create(%Scope{} = scope, body, actor) do
    with {:ok, attrs} <- attrs(body) do
      digest = digest(scope, "inbox_announcement.published", Jason.encode!(body))

      case Relay.Inbox.create_announcement(scope, attrs, digest, actor) do
        {:created, id} ->
          location = "/v1/inbox/announcements/" <> Relay.ExternalId.encode("ann", id)
          {:ok, {201, [{"location", location}], view(Relay.Inbox.announcement_record(id))}}

        :subtenant_not_found ->
          {:error, field("/subtenant", "not_found", "no active sub-tenant has this identifier")}

        :topic_not_found ->
          {:error, field("/topic", "not_found", "no active topic has this key")}

        :tenant_inactive ->
          {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}
      end
    end
  end

  defp attrs(body) do
    tags = body["tags"] || []
    content = body["content"] || %{}

    with {:ok, audience} <- audience(body),
         {:ok, expires_at} <- expires_at(body["expires_at"]),
         :ok <- content(content, tags) do
      {:ok,
       Map.merge(audience, %{
         category: body["category"],
         tags: tags,
         severity: body["severity"],
         content: content,
         locale: body["locale"],
         dir: body["dir"],
         expires_at: expires_at
       })}
    end
  end

  defp audience(%{"audience" => "tenant"} = body) do
    if body["subtenant"] == nil and body["topic"] == nil,
      do: {:ok, %{audience: "tenant", subtenant_id: nil, topic_key: nil}},
      else: {:error, field("/audience", "not_allowed", "a tenant audience names no target")}
  end

  defp audience(%{"audience" => "subtenant", "subtenant" => text} = body)
       when is_binary(text) and not is_map_key(body, "topic") do
    case Relay.ExternalId.decode(text, ["stn"]) do
      {:ok, id} -> {:ok, %{audience: "subtenant", subtenant_id: id, topic_key: nil}}
      {:error, _error} -> {:error, field("/subtenant", "invalid_format", "a sub-tenant id")}
    end
  end

  defp audience(%{"audience" => "topic", "topic" => key} = body)
       when is_binary(key) and not is_map_key(body, "subtenant"),
       do: {:ok, %{audience: "topic", subtenant_id: nil, topic_key: key}}

  defp audience(%{"audience" => audience}) when audience in @audiences,
    do: {:error, field("/audience", "required", "subtenant needs subtenant, topic needs topic")}

  defp audience(_body),
    do: {:error, field("/audience", "unsupported_value", "tenant, subtenant or topic")}

  defp expires_at(nil), do: {:ok, nil}

  defp expires_at(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> future(at)
      _invalid -> {:error, field("/expires_at", "invalid_format", "RFC 3339")}
    end
  end

  defp expires_at(_value), do: {:error, field("/expires_at", "invalid_format", "RFC 3339")}

  defp future(at) do
    if DateTime.compare(at, Relay.Clock.utc_now()) == :gt,
      do: {:ok, at},
      else: {:error, field("/expires_at", "not_allowed", "a future time")}
  end

  # IN-49
  defp content(content, tags) when is_map(content) and is_list(tags) do
    case Relay.Inbox.check_item(content, %{tags: tags, group_key: nil}) do
      :ok ->
        :ok

      {:error, :inbox_item_too_large, detail} ->
        pointer = "/content" <> (detail["field"] || "")
        {:error, field(pointer, "too_long", "the content breaks an inbox limit")}

      {:error, :schema_violation, detail} ->
        pointer = "/content" <> (detail["field"] || "")
        {:error, field(pointer, "invalid_format", "an action URL is https")}
    end
  end

  defp content(_content, _tags),
    do: {:error, field("/content", "invalid_format", "an object")}

  # IN-3
  @doc "Reads an announcement of the scope."
  @spec get(Scope.t(), Relay.Id.t()) :: answer()
  def get(%Scope{} = scope, announcement_id) do
    case Relay.Inbox.read_announcement(scope, announcement_id) do
      {:ok, nil} -> {:error, not_found()}
      {:ok, row} -> {:ok, {200, [], view(row)}}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # IN-3
  # IN-16
  @doc "Retracts an announcement inside the request's transaction: it leaves every list and counter of its audience at once."
  @spec retract(Scope.t(), Relay.Id.t(), Relay.Actor.t()) :: answer()
  def retract(%Scope{} = scope, announcement_id, actor) do
    ref = Relay.ExternalId.encode("ann", announcement_id)
    digest = digest(scope, "inbox_announcement.retracted", ref)

    case Relay.Inbox.retract_announcement(announcement_id, digest, actor) do
      result when result in [:retracted, :already_closed] ->
        {:ok, {200, [], view(Relay.Inbox.announcement_record(announcement_id))}}

      :not_found ->
        {:error, not_found()}
    end
  end

  defp view(row) do
    %{
      "object" => "inbox_announcement",
      "id" => Relay.ExternalId.encode("ann", row["id"]),
      "audience" => row["audience"],
      "subtenant" => row["subtenant_id"] && Relay.ExternalId.encode("stn", row["subtenant_id"]),
      "topic" => row["topic_key"],
      "category" => row["category"],
      "tags" => row["tags"] || [],
      "severity" => row["severity"],
      "content" => row["content"],
      "locale" => row["locale"],
      "dir" => row["dir"],
      "state" => row["state"],
      "published_at" => row["published_at"],
      "expires_at" => row["expires_at"],
      "closed_at" => row["closed_at"]
    }
  end

  defp digest(scope, action, ref) do
    environment = Atom.to_string(scope.environment)
    canonical = Relay.Canonical.encode!([action, {:bytes, scope.tenant_id}, environment, ref])
    :crypto.hash(:sha256, canonical)
  end

  @doc "The error of an announcement the scope does not have."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:inbox_announcement_not_found, "no such announcement")

  defp unavailable,
    do: Relay.Error.new(:service_unavailable, "the announcement cannot be read now")

  defp field(pointer, code, detail) do
    error = %{pointer: pointer, code: code, detail: detail}

    Relay.Error.new(:validation_failed, "the announcement breaks a field rule", %{errors: [error]})
  end
end
