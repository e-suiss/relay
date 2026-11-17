defmodule Relay.Api.WebhookSources do
  @moduledoc """
  Completion sources on the server API and their inbound endpoint (WH-68, WH-50, E-48). A source is an external system that notifies Relay when a long-running job ends; it is registered (`201`) with the `whpk_` public key of its `v1a` signatures or the identifier of the secret reference that holds its `v1` secret, listed, read and archived. Nothing is deleted, and a secret is never taken or shown here (TN-26). The writes run inside the request's transaction and are audited.

  `inbound/1` is the endpoint a source posts to (`/inbound/v1/completions/{tenant}/{environment}/sources/{webhook_source_id}`): the path names the tenant (`ten_…`), the environment and the source (`whs_…`). The notification is verified on its raw body and committed as a receipt with its job before the `200` (`Relay.Webhooks.accept_completion/3`); a repeated `webhook-id` is acknowledged and not processed again. An unknown or archived source is `404`, a request that does not verify `401`, a verified body that is not a notification `400`, and a receipt that could not be committed `503`, so the source sends it again.
  """

  alias Relay.Api.Gate
  alias Relay.Api.Page
  alias Relay.Api.Pagination
  alias Relay.Api.Views
  alias Relay.Scope

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}
  @type notification :: %{
          required(:tenant) => String.t(),
          required(:environment) => String.t(),
          required(:source) => String.t(),
          required(:body) => binary(),
          required(:headers) => [{String.t(), String.t()}]
        }

  @states ~w(active archived)
  @one_key "give exactly one of public_key and secret_ref_id"

  # WH-68
  @doc "The API view of a source row: its public key in the `whpk_` form, or the identifier of its secret reference."
  @spec view(map()) :: map()
  def view(s) do
    %{
      "object" => "webhook_source",
      "id" => Views.id("whs", s["id"]),
      "name" => s["name"],
      "scheme" => s["scheme"],
      "public_key" => Relay.Webhooks.public_key(s["public_key"]),
      "secret_ref_id" => Views.id("sec", s["secret_ref_id"]),
      "state" => s["state"],
      "created_at" => s["created_at"],
      "updated_at" => s["updated_at"],
      "archived_at" => s["archived_at"]
    }
  end

  # WH-68
  @doc "Reads the `state` filter of a list request."
  @spec filters(map()) :: {:ok, String.t() | nil} | {:error, Relay.Error.t()}
  def filters(query) do
    case Map.get(query, "state") do
      state when state == nil or state in @states -> {:ok, state}
      _other -> {:error, Gate.field_error("/state", "unsupported_value", "unknown state")}
    end
  end

  # WH-68
  # TN-26
  @doc "Registers a source inside the request's transaction; `201` with its view. The body names exactly one of `public_key` and `secret_ref_id`."
  @spec create(Scope.t(), map(), Relay.Actor.t()) :: answer()
  def create(%Scope{} = scope, body, actor) do
    with {:ok, key} <- key(body) do
      attrs = Map.put(key, :name, body["name"])
      digest = Gate.digest(scope, "webhook_source.created", attrs.name)
      created(Relay.Webhooks.source_create(attrs, digest, actor))
    end
  end

  defp key(%{"public_key" => _key, "secret_ref_id" => _ref}),
    do: {:error, Gate.field_error("/secret_ref_id", "conflict", @one_key)}

  defp key(%{"public_key" => text}) do
    case Relay.Webhooks.source_public_key(text) do
      {:ok, public_key} -> {:ok, %{scheme: "v1a", public_key: public_key}}
      :error -> {:error, Gate.field_error("/public_key", "invalid_format", "not a whpk_ key")}
    end
  end

  defp key(%{"secret_ref_id" => text}) do
    case Relay.ExternalId.decode(text, ["sec"]) do
      {:ok, id} -> {:ok, %{scheme: "v1", secret_ref_id: id}}
      {:error, _error} -> {:error, no_secret()}
    end
  end

  defp key(_neither), do: {:error, Gate.field_error("/public_key", "required", @one_key)}

  defp created({:created, id}) do
    location = {"location", "/v1/webhook_sources/" <> Views.id("whs", id)}
    {:ok, {201, [location], view(Relay.Webhooks.source(id))}}
  end

  defp created({:secret_not_found, _id}), do: {:error, no_secret()}

  defp created({:limit_reached, _id}),
    do: {:error, Relay.Error.new(:webhook_source_limit_reached, "the source limit is reached")}

  defp created({:tenant_inactive, _id}),
    do: {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}

  # WH-68
  @doc "Reads a source."
  @spec get(Scope.t(), Relay.Id.t()) :: answer()
  def get(%Scope{} = scope, id) do
    case Relay.Webhooks.get_source(scope, id) do
      {:ok, %{} = source} -> {:ok, {200, [], view(source)}}
      {:ok, nil} -> {:error, not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # WH-68
  # API-56
  @doc "Lists sources, newest first."
  @spec list(Scope.t(), String.t() | nil, Pagination.page(), String.t()) :: answer()
  def list(%Scope{} = scope, state, page, endpoint) do
    case Relay.Webhooks.list_sources(scope, state, page.cursor, page.limit) do
      {:ok, rows} ->
        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &view/1, &position/1),
             do: {:ok, {200, [], body}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # WH-68
  @doc "Archives a source inside the request's transaction; archiving an archived source returns it."
  @spec archive(Scope.t(), Relay.Id.t(), Relay.Actor.t()) :: answer()
  def archive(%Scope{} = scope, id, actor) do
    digest = Gate.digest(scope, "webhook_source.archived", Relay.Id.to_string(id))

    case Relay.Webhooks.source_archive(id, digest, actor) do
      :not_found -> {:error, not_found()}
      _archived -> {:ok, {200, [], view(Relay.Webhooks.source(id))}}
    end
  end

  # WH-68
  # WH-49
  # T-40
  @doc "Verifies and records a completion notification of the source the path names; returns the HTTP status and the JSON body."
  @spec inbound(notification()) :: {pos_integer(), map()}
  def inbound(%{body: body, headers: headers} = notification) when is_binary(body) do
    with {:ok, tenant_id} <- Relay.ExternalId.decode(notification.tenant, ["ten"]),
         {:ok, source_id} <- Relay.ExternalId.decode(notification.source, ["whs"]),
         {:ok, environment} <- Relay.Environment.cast(notification.environment),
         {:ok, scope} <- Scope.new(tenant_id, environment) do
      request = %{body: body, headers: headers, now: Relay.Clock.utc_now()}
      answered(Relay.Webhooks.accept_completion(scope, source_id, request))
    else
      _invalid -> {404, %{"error" => "not_found"}}
    end
  end

  # AG-42
  # AG-37
  # WH-49
  @doc "Verifies and records an A2A push notification of the source the path names; returns the HTTP status and the JSON body. A version Relay does not serve is answered with the problem A2A names for it."
  @spec inbound_task(notification()) :: {pos_integer(), map()}
  def inbound_task(%{body: body, headers: headers} = notification) when is_binary(body) do
    with {:ok, tenant_id} <- Relay.ExternalId.decode(notification.tenant, ["ten"]),
         {:ok, source_id} <- Relay.ExternalId.decode(notification.source, ["whs"]),
         {:ok, environment} <- Relay.Environment.cast(notification.environment),
         {:ok, scope} <- Scope.new(tenant_id, environment) do
      request = %{body: body, headers: headers, now: Relay.Clock.utc_now()}
      answered(Relay.Webhooks.accept_task_notification(scope, source_id, request))
    else
      _invalid -> {404, %{"error" => "not_found"}}
    end
  end

  defp answered({:error, :version_not_supported}) do
    {400,
     %{
       "error" => "version_not_supported",
       "type" => "https://a2a-protocol.org/errors/version-not-supported",
       "title" => "Version not supported",
       "status" => 400,
       "supported" => Relay.Agents.protocol_versions("a2a")
     }}
  end

  defp answered({:ok, _recorded_or_duplicate}), do: {200, %{}}
  defp answered({:error, :not_found}), do: {404, %{"error" => "not_found"}}
  defp answered({:error, :unauthorized}), do: {401, %{"error" => "unauthorized"}}
  defp answered({:error, :malformed}), do: {400, %{"error" => "malformed"}}
  defp answered({:error, :unavailable}), do: {503, %{"error" => "unavailable"}}

  defp position(row), do: {row["cursor_at"], row["id"]}

  @doc "The error of an unknown source identifier."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:webhook_source_not_found, "no source has this id")

  defp no_secret,
    do: Gate.field_error("/secret_ref_id", "not_found", "no active source secret has this id")

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
