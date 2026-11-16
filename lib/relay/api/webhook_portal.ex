defmodule Relay.Api.WebhookPortal do
  @moduledoc """
  The backend of the embeddable webhook portal (WH-46, WH-47, WH-48). A tenant backend mints a portal token for one consumer (`prepare_token/3`); the portal then acts with it for that consumer only: it lists the tenant's event types, lists, adds, changes and archives the consumer's endpoints, rotates their signing keys, reads their health, sends a test event, reads the delivery log with its attempts and the missed events, resends one message and recovers an endpoint.

  Every operation is the server operation of the same name restricted to the consumer of the token (`t:portal/0`): an endpoint, message or attempt of another consumer is not found, exactly like one of another tenant or environment. An endpoint the portal adds is an `https` endpoint of use `destination` of that consumer, within the limit of endpoints per consumer (WH-52). Adding, changing and archiving an endpoint, rotating a key and recovering are audited with the actor of the portal (WH-48).

  A function that reaches the key store or resolves an address (`prepare_token/3`, `prepare_create/2`, `prepare_update/3`, `prepare_rotation/3`, `attempt/3`) runs outside any transaction; a function documented as running inside the request's transaction checks the endpoint's or message's consumer there again.
  """

  alias Relay.Api.Gate
  alias Relay.Api.Page
  alias Relay.Api.Pagination
  alias Relay.Api.Views
  alias Relay.Api.WebhookConsumers
  alias Relay.Api.WebhookEventTypes
  alias Relay.Api.Webhooks
  alias Relay.Scope

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @typedoc "The consumer a portal token is scoped to, in the scope of the token."
  @type portal :: %{scope: Scope.t(), consumer_id: Relay.Id.t()}

  @states ~w(pending scheduled in_flight held delivered failed_permanent exhausted expired
             window_exceeded dead_lettered cancelled)
  @path "/v1/portal/webhook_endpoints/"

  # WH-47
  @doc "Checks that a consumer can get a portal token and signs one for `audiences`, outside any transaction: `201` with the token, the consumer and when it expires. An archived consumer gets none."
  @spec prepare_token(Scope.t(), Relay.Id.t(), map()) :: answer()
  def prepare_token(%Scope{} = scope, consumer_id, audiences) do
    with :ok <- mintable(Relay.Webhooks.get_consumer(scope, consumer_id)),
         {:ok, issued} <- Relay.Access.issue_portal_token(scope, consumer_id, audiences) do
      {:ok,
       {201, [],
        %{
          "object" => "webhook_portal_token",
          "token" => issued.token,
          "consumer_id" => Views.id("whc", consumer_id),
          "expires_at" => issued.expires_at
        }}}
    end
  end

  defp mintable({:ok, %{"state" => "active"}}), do: :ok
  defp mintable({:ok, %{}}), do: {:error, WebhookConsumers.archived()}
  defp mintable({:ok, nil}), do: {:error, WebhookConsumers.not_found()}
  defp mintable({:error, _reason}), do: {:error, unavailable()}

  # WH-47
  # E-25
  @doc "Verifies a portal token for `audiences` and names the consumer it is scoped to. The token of a consumer that no longer exists or is archived is `auth_invalid_token`."
  @spec authenticate(String.t(), map()) :: {:ok, portal()} | {:error, Relay.Error.t()}
  def authenticate(token, audiences) when is_binary(token) do
    with {:ok, %{scope: scope, consumer_id: consumer_id}} <-
           Relay.Access.verify_portal_token(token, audiences),
         :ok <- live(Relay.Webhooks.get_consumer(scope, consumer_id)) do
      {:ok, %{scope: scope, consumer_id: consumer_id}}
    end
  end

  defp live({:ok, %{"state" => "active"}}), do: :ok
  defp live({:ok, _missing_or_archived}), do: {:error, gone()}
  defp live({:error, %Relay.Error{code: :not_found}}), do: {:error, gone()}
  defp live({:error, _reason}), do: {:error, unavailable()}

  # WH-48
  @doc "The audit actor of the portal of a consumer: the portal acts, on behalf of the consumer."
  @spec actor(portal()) :: Relay.Actor.t()
  def actor(%{consumer_id: consumer_id}) do
    consumer = Views.id("whc", consumer_id)
    {:ok, actor} = Relay.Actor.new(:api_client, "webhook_portal:" <> consumer, consumer)
    actor
  end

  # WH-46
  # API-56
  @doc "Lists the tenant's active event types with the schema, identifiers and example of their current version."
  @spec event_types(portal(), Pagination.page(), String.t()) :: answer()
  def event_types(%{scope: scope}, page, endpoint),
    do: WebhookEventTypes.list(scope, "active", page, endpoint)

  # WH-47
  # API-56
  @doc "Lists the endpoints of the consumer, newest first."
  @spec endpoints(portal(), Pagination.page(), String.t()) :: answer()
  def endpoints(%{scope: scope, consumer_id: consumer_id}, page, endpoint) do
    filters = %{use: nil, state: nil, consumer_id: consumer_id}
    Webhooks.list(scope, filters, page, endpoint)
  end

  # WH-40
  # WH-46
  # WH-52
  @doc "Checks an endpoint creation of the portal and makes its signing key, outside any transaction; the use, the consumer and the destination kind come from the token, never from the request."
  @spec prepare_create(portal(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def prepare_create(%{scope: scope, consumer_id: consumer_id}, body) do
    case Relay.Webhooks.get_consumer(scope, consumer_id) do
      {:ok, %{"state" => "active", "key" => key}} ->
        request =
          body
          |> Map.take(["event_types", "signature_scheme", "description"])
          |> Map.merge(%{
            "use" => "destination",
            "consumer" => key,
            "destination" => %{"kind" => "https", "url" => body["url"]}
          })

        own_error(Webhooks.prepare_create(scope, request))

      {:ok, _missing_or_archived} ->
        {:error, gone()}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # WH-46
  # WH-48
  # WH-52
  @doc "Creates a prepared endpoint for the consumer inside the request's transaction; `201` with the endpoint and, for a `v1` key, its secret."
  @spec create(portal(), map(), String.t(), Relay.Actor.t()) :: answer()
  def create(%{scope: scope}, prepared, api_version, actor) do
    case Webhooks.create(scope, prepared, api_version, actor) do
      {:ok, {201, headers, body}} ->
        location = {"location", @path <> body["id"]}
        {:ok, {201, List.keystore(headers, "location", 0, location), body}}

      {:error, error} ->
        own_error({:error, error})
    end
  end

  # WH-47
  @doc "Reads an endpoint of the consumer."
  @spec get(portal(), Relay.Id.t()) :: answer()
  def get(portal, id) do
    with {:ok, endpoint} <- owned(portal, id),
         do: {:ok, {200, [Webhooks.etag(endpoint["version"])], Webhooks.view(endpoint)}}
  end

  # WH-40
  # WH-46
  @doc "Turns a portal change into the change of the server operation and runs its early address check, outside any transaction. A new URL replaces the address of the endpoint's `https` destination and leaves the rest of it as it is."
  @spec prepare_update(portal(), Relay.Id.t(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def prepare_update(portal, id, body) do
    with {:ok, endpoint} <- owned(portal, id),
         {:ok, patch} <- patch(endpoint, body),
         :ok <- own_error(Webhooks.prepare_update(patch)),
         do: {:ok, patch}
  end

  defp patch(%{"kind" => "https"} = endpoint, %{"url" => url} = body) do
    destination = Map.put(Webhooks.view(endpoint)["destination"], "url", url)
    {:ok, body |> plain() |> Map.put("destination", destination)}
  end

  defp patch(_endpoint, %{"url" => _url}),
    do: {:error, Gate.field_error("/url", "not_allowed", "only an https endpoint has a URL")}

  defp patch(_endpoint, body), do: {:ok, plain(body)}

  defp plain(body), do: Map.take(body, ["event_types", "description", "state"])

  # WH-46
  # WH-48
  @doc "Applies a prepared change to an endpoint of the consumer inside the request's transaction; `expected_version` is the version an `If-Match` named, or `nil`."
  @spec update(portal(), Relay.Id.t(), map(), pos_integer() | nil, Relay.Actor.t()) :: answer()
  def update(%{scope: scope} = portal, id, patch, expected_version, actor) do
    with {:ok, _endpoint} <- own(portal, id),
         do: own_error(Webhooks.update(scope, id, patch, expected_version, actor))
  end

  # WH-46
  # WH-48
  @doc "Archives an endpoint of the consumer inside the request's transaction."
  @spec archive(portal(), Relay.Id.t(), Relay.Actor.t()) :: answer()
  def archive(%{scope: scope} = portal, id, actor) do
    with {:ok, _endpoint} <- own(portal, id), do: Webhooks.archive(scope, id, actor)
  end

  # WH-6
  # WH-46
  @doc "Checks a key rotation of an endpoint of the consumer and makes the new key, outside any transaction."
  @spec prepare_rotation(portal(), Relay.Id.t(), map() | nil) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def prepare_rotation(%{scope: scope} = portal, id, body) do
    with {:ok, _endpoint} <- owned(portal, id), do: Webhooks.prepare_rotation(scope, id, body)
  end

  # WH-6
  # WH-48
  @doc "Rotates the signing key of an endpoint of the consumer to a prepared key inside the request's transaction."
  @spec rotate(portal(), Relay.Id.t(), map(), Relay.Actor.t()) :: answer()
  def rotate(%{scope: scope} = portal, id, prepared, actor) do
    with {:ok, _endpoint} <- own(portal, id), do: Webhooks.rotate(scope, id, prepared, actor)
  end

  # WH-39
  # WH-46
  @doc "Reads the health of an endpoint of the consumer."
  @spec health(portal(), Relay.Id.t()) :: answer()
  def health(%{scope: scope} = portal, id) do
    with {:ok, _endpoint} <- owned(portal, id), do: Webhooks.health(scope, id)
  end

  # WH-45 (3)
  # WH-46
  @doc "Sends the test event of an endpoint of the consumer inside the request's transaction."
  @spec test(portal(), Relay.Id.t(), map() | nil) :: answer()
  def test(%{scope: scope} = portal, id, body) do
    with {:ok, _endpoint} <- own(portal, id), do: Webhooks.test(scope, id, body)
  end

  # WH-31
  # WH-37
  # WH-46
  # WH-48
  @doc "Recovers an endpoint of the consumer inside the request's transaction: its missed events since `since` start their schedule again, and the operation is audited. Only an active endpoint is recovered."
  @spec recover(portal(), Relay.Id.t(), map(), Relay.Actor.t()) :: answer()
  def recover(%{scope: scope} = portal, id, body, actor) do
    with {:ok, endpoint} <- own(portal, id),
         :ok <- usable(endpoint["state"]),
         {:ok, %DateTime{} = since} <- instant(body, "since"),
         {:ok, until} <- instant(body, "until") do
      digest = Gate.digest(scope, "webhook_endpoint.updated", Relay.Id.to_string(id))
      selected = Relay.Webhooks.portal_recover(id, since, until, digest, actor)

      {:ok,
       {200, [],
        %{
          "object" => "webhook_recovery",
          "operation" => "recover",
          "endpoint_id" => Views.id("whe", id),
          "selected" => selected
        }}}
    else
      {:ok, nil} -> {:error, Gate.field_error("/since", "required", "since is required")}
      {:error, error} -> {:error, error}
    end
  end

  # WH-30 (2)
  # WH-46
  # API-56
  @doc "Lists the missed events of an endpoint of the consumer, newest first: its messages in a terminal state other than delivered and those kept while it was disabled."
  @spec missed(portal(), Relay.Id.t(), map(), Pagination.page(), String.t()) :: answer()
  def missed(portal, id, query, page, endpoint) do
    with {:ok, _endpoint} <- owned(portal, id),
         {:ok, filters} <- filters(Map.delete(query, "endpoint_id")) do
      listed(portal, %{filters | endpoint_id: id, missed: true}, page, endpoint)
    end
  end

  # WH-30 (3)
  # WH-47
  # API-56
  @doc "Lists the delivery log of the consumer, newest first, by endpoint, state, event type and time."
  @spec messages(portal(), map(), Pagination.page(), String.t()) :: answer()
  def messages(portal, query, page, endpoint) do
    with {:ok, filters} <- filters(query), do: listed(portal, filters, page, endpoint)
  end

  defp listed(%{scope: scope, consumer_id: consumer_id}, filters, page, endpoint) do
    case Relay.Webhooks.portal_messages(scope, consumer_id, filters, page.cursor, page.limit) do
      {:ok, rows} ->
        view = &Webhooks.message_view/1

        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, view, &position/1),
             do: {:ok, {200, [], body}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  defp position(row), do: {row["created_at"], row["id"]}

  defp filters(query) do
    with {:ok, endpoint_id} <- endpoint_filter(Map.get(query, "endpoint_id")),
         {:ok, state} <- state_filter(Map.get(query, "state")),
         {:ok, event_type} <- type_filter(Map.get(query, "event_type")),
         {:ok, created_after} <- instant(query, "created_after"),
         {:ok, created_before} <- instant(query, "created_before") do
      {:ok,
       %{
         endpoint_id: endpoint_id,
         state: state,
         event_type: event_type,
         created_after: created_after,
         created_before: created_before,
         missed: false
       }}
    end
  end

  defp endpoint_filter(nil), do: {:ok, nil}

  defp endpoint_filter(text) do
    case Relay.ExternalId.decode(text, ["whe"]) do
      {:ok, id} -> {:ok, id}
      {:error, _error} -> {:error, Gate.field_error("/endpoint_id", "invalid_format", "bad id")}
    end
  end

  defp state_filter(state) when state == nil or state in @states, do: {:ok, state}

  defp state_filter(_other),
    do: {:error, Gate.field_error("/state", "unsupported_value", "unknown state")}

  defp type_filter(type) when is_nil(type) or (is_binary(type) and byte_size(type) <= 128),
    do: {:ok, type}

  defp type_filter(_other),
    do: {:error, Gate.field_error("/event_type", "invalid_format", "not an event type")}

  defp instant(source, name) do
    with text when is_binary(text) <- Map.get(source, name),
         {:ok, at, _offset} <- DateTime.from_iso8601(text) do
      {:ok, at}
    else
      nil -> {:ok, nil}
      _other -> {:error, Gate.field_error("/" <> name, "invalid_format", "not a timestamp")}
    end
  end

  # WH-47
  @doc "Reads a message of the consumer."
  @spec message(portal(), Relay.Id.t()) :: answer()
  def message(%{scope: scope, consumer_id: consumer_id}, id) do
    case Relay.Webhooks.get_portal_message(scope, consumer_id, id) do
      {:ok, %{} = message} -> {:ok, {200, [], Webhooks.message_view(message)}}
      {:ok, nil} -> {:error, no_message()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # WH-10
  # WH-47
  # API-56
  @doc "Lists the attempts of a message of the consumer in attempt order, without the answers."
  @spec attempts(portal(), Relay.Id.t(), Pagination.page(), String.t()) :: answer()
  def attempts(%{scope: scope, consumer_id: consumer_id}, message_id, page, endpoint) do
    position = &{DateTime.from_unix!(&1["attempt_no"], :microsecond), &1["id"]}
    read = Relay.Webhooks.portal_attempts(scope, consumer_id, message_id, page.cursor, page.limit)

    case read do
      {:ok, :not_found} ->
        {:error, no_message()}

      {:ok, rows} ->
        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &attempt_view/1, position),
             do: {:ok, {200, [], body}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # WH-10
  # WH-47
  @doc "Reads one attempt of a message of the consumer with the kept part of the answer, outside any transaction."
  @spec attempt(portal(), Relay.Id.t(), Relay.Id.t()) :: answer()
  def attempt(%{scope: scope, consumer_id: consumer_id}, message_id, id) do
    case Relay.Webhooks.portal_attempt(scope, consumer_id, message_id, id) do
      {:ok, %{} = attempt} ->
        body = answer_view(attempt["response_body"], attempt["response_truncated"])
        {:ok, {200, [], Map.put(attempt_view(attempt), "response_body", body)}}

      {:ok, :not_found} ->
        {:error, no_message()}

      {:ok, nil} ->
        {:error, Relay.Error.new(:webhook_attempt_not_found, "no attempt has this id")}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  defp attempt_view(a) do
    %{
      "object" => "webhook_attempt",
      "id" => Views.id("wha", a["id"]),
      "message_id" => Views.id("whm", a["message_id"]),
      "endpoint_id" => Views.id("whe", a["endpoint_id"]),
      "attempt_no" => a["attempt_no"],
      "trigger" => a["trigger_kind"],
      "result" => a["result"],
      "failure_code" => a["failure_code"],
      "response_status" => a["response_status"],
      "duration_ms" => a["duration_ms"],
      "webhook_timestamp" => a["webhook_timestamp"],
      "body_digest" => Gate.hex(a["body_digest"]),
      "signature" => a["signature"],
      "destination_ip" => a["destination_ip"],
      "retry_after" => a["retry_after_seconds"] && Webhooks.iso(a["retry_after_seconds"]),
      "started_at" => a["started_at"],
      "finished_at" => a["finished_at"]
    }
  end

  defp answer_view(nil, _truncated), do: nil

  defp answer_view(body, truncated) do
    if String.valid?(body),
      do: %{"encoding" => "utf8", "content" => body, "truncated" => truncated},
      else: %{"encoding" => "base64", "content" => Base.encode64(body), "truncated" => truncated}
  end

  # WH-32
  # WH-46
  @doc "Makes one attempt for a message of the consumer now, inside the request's transaction: `202` with the message. A message that is being attempted is `webhook_message_in_flight`; only an active endpoint is attempted."
  @spec resend(portal(), Relay.Id.t()) :: answer()
  def resend(%{consumer_id: consumer_id}, id) do
    with %{} = message <- Relay.Webhooks.portal_message(consumer_id, id),
         :ok <- usable(message["endpoint_state"]),
         :ok <- idle(message["state"]),
         :ok <- Relay.Webhooks.resend(id) do
      {:ok, {202, [], Webhooks.message_view(message)}}
    else
      nil -> {:error, no_message()}
      {:error, %Relay.Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp idle("in_flight"),
    do: {:error, Relay.Error.new(:webhook_message_in_flight, "an attempt of the message runs")}

  defp idle(_state), do: :ok

  defp usable("active"), do: :ok

  defp usable("archived"),
    do: {:error, Relay.Error.new(:webhook_endpoint_archived, "the endpoint is archived")}

  defp usable(_paused_or_disabled),
    do: {:error, Relay.Error.new(:webhook_endpoint_state_conflict, "the endpoint is not active")}

  defp owned(%{scope: scope, consumer_id: consumer_id}, id) do
    case Relay.Webhooks.get_endpoint(scope, id) do
      {:ok, %{"consumer_id" => ^consumer_id} = endpoint} -> {:ok, endpoint}
      {:ok, _missing_or_foreign} -> {:error, Webhooks.not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp own(%{consumer_id: consumer_id}, id) do
    case Relay.Webhooks.endpoint(id) do
      %{"consumer_id" => ^consumer_id} = endpoint -> {:ok, endpoint}
      _missing_or_foreign -> {:error, Webhooks.not_found()}
    end
  end

  defp own_error({:error, %Relay.Error{code: :webhook_consumer_archived}}), do: {:error, gone()}

  defp own_error({:error, %Relay.Error{details: %{errors: [_ | _] = errors}} = error}) do
    if Enum.any?(errors, &(Map.get(&1, :pointer) == "/consumer")),
      do: {:error, gone()},
      else: {:error, %{error | details: %{error.details | errors: Enum.map(errors, &flat/1)}}}
  end

  defp own_error(other), do: other

  defp flat(%{pointer: "/destination/url"} = error), do: %{error | pointer: "/url"}
  defp flat(error), do: error

  defp no_message, do: Relay.Error.new(:webhook_message_not_found, "no message has this id")

  defp gone,
    do: Relay.Error.new(:auth_invalid_token, "the consumer of the portal token is not active")

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
