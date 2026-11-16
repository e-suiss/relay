defmodule Relay.Api.WebhookPortal do
  @moduledoc """
  The backend of the embeddable webhook portal (WH-46, WH-47, WH-48). A tenant backend mints a portal token for one consumer (`prepare_token/3`); the portal then acts with it for that consumer only: it lists the tenant's event types, lists, adds, changes and archives the consumer's endpoints, rotates their signing keys, reads their health, sends a test event, reads the delivery log with its attempts and the missed events, resends one message and recovers an endpoint (`Relay.Api.WebhookMessages`).

  Every operation is the server operation of the same name restricted to the consumer of the token (`t:portal/0`): an endpoint, message or attempt of another consumer is not found, exactly like one of another tenant or environment. An endpoint the portal adds is an `https` endpoint of use `destination` of that consumer, within the limit of endpoints per consumer (WH-52). Adding, changing and archiving an endpoint, rotating a key, resending and recovering are audited with the actor of the portal (WH-48).

  A function that reaches the key store or resolves an address (`prepare_token/3`, `prepare_create/2`, `prepare_update/3`, `prepare_rotation/3`, `attempt/3`) runs outside any transaction; a function documented as running inside the request's transaction checks the endpoint's or message's consumer there again.
  """

  alias Relay.Api.Gate
  alias Relay.Api.Page
  alias Relay.Api.Pagination
  alias Relay.Api.Views
  alias Relay.Api.WebhookConsumers
  alias Relay.Api.WebhookEventTypes
  alias Relay.Api.WebhookMessages
  alias Relay.Api.Webhooks
  alias Relay.Scope

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @typedoc "The consumer a portal token is scoped to, in the scope of the token."
  @type portal :: %{scope: Scope.t(), consumer_id: Relay.Id.t()}

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
  @doc "Recovers an endpoint of the consumer inside the request's transaction, as the server operation does: its missed events since `since` start their schedule again in jobs, and the operation is audited."
  @spec recover(portal(), Relay.Id.t(), map(), Relay.Actor.t()) :: answer()
  def recover(%{scope: scope} = portal, id, body, actor) do
    with {:ok, _endpoint} <- own(portal, id),
         do: WebhookMessages.recovery(scope, "recover", id, body, actor)
  end

  # WH-30 (2)
  # WH-46
  # API-56
  @doc "Lists the missed events of an endpoint of the consumer, newest first: its messages in a terminal state other than delivered and those kept while it was disabled."
  @spec missed(portal(), Relay.Id.t(), map(), Pagination.page(), String.t()) :: answer()
  def missed(%{scope: scope} = portal, id, query, page, endpoint) do
    with {:ok, _endpoint} <- owned(portal, id),
         {:ok, filters} <- WebhookMessages.missed_filters(query) do
      WebhookMessages.missed(scope, id, filters, page, endpoint)
    end
  end

  # WH-30 (3)
  # WH-47
  # API-56
  @doc "Lists the delivery log of the consumer, newest first, by endpoint, state, event type and time."
  @spec messages(portal(), map(), Pagination.page(), String.t()) :: answer()
  def messages(%{scope: scope, consumer_id: consumer_id}, query, page, endpoint) do
    with {:ok, filters} <- WebhookMessages.filters(Map.delete(query, "event_id")),
         {:ok, rows} <- log(scope, consumer_id, filters, page),
         {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &view/1, &position/1),
         do: {:ok, {200, [], body}}
  end

  defp log(scope, consumer_id, filters, page) do
    case Relay.Webhooks.portal_messages(scope, consumer_id, filters, page.cursor, page.limit) do
      {:ok, rows} -> {:ok, rows}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp view(message), do: WebhookMessages.view(message)
  defp position(row), do: {row["created_at"], row["id"]}

  # WH-47
  @doc "Reads a message of the consumer."
  @spec message(portal(), Relay.Id.t()) :: answer()
  def message(portal, id) do
    with {:ok, message} <- mine(portal, id), do: {:ok, {200, [], view(message)}}
  end

  # WH-10
  # WH-47
  # API-56
  @doc "Lists the attempts of a message of the consumer in attempt order, without the answers."
  @spec attempts(portal(), Relay.Id.t(), Pagination.page(), String.t()) :: answer()
  def attempts(%{scope: scope} = portal, message_id, page, endpoint) do
    with {:ok, _message} <- mine(portal, message_id),
         do: WebhookMessages.attempts(scope, message_id, page, endpoint)
  end

  # WH-10
  # WH-47
  @doc "Reads one attempt of a message of the consumer with the kept part of the answer, outside any transaction."
  @spec attempt(portal(), Relay.Id.t(), Relay.Id.t()) :: answer()
  def attempt(%{scope: scope} = portal, message_id, id) do
    with {:ok, _message} <- mine(portal, message_id),
         do: WebhookMessages.attempt(scope, message_id, id)
  end

  defp mine(%{scope: scope, consumer_id: consumer_id}, id) do
    case Relay.Webhooks.get_portal_message(scope, consumer_id, id) do
      {:ok, %{} = message} -> {:ok, message}
      {:ok, nil} -> {:error, WebhookMessages.not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # WH-32
  # WH-46
  # WH-48
  @doc "Makes one attempt for a message of the consumer now, inside the request's transaction, as the server operation does: `202` with the message, audited."
  @spec resend(portal(), Relay.Id.t(), Relay.Actor.t()) :: answer()
  def resend(%{scope: scope, consumer_id: consumer_id}, id, actor) do
    case Relay.Webhooks.portal_message(consumer_id, id) do
      nil -> {:error, WebhookMessages.not_found()}
      _message -> WebhookMessages.resend(scope, id, actor)
    end
  end

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

  defp gone,
    do: Relay.Error.new(:auth_invalid_token, "the consumer of the portal token is not active")

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
