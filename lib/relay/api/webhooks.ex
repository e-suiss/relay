defmodule Relay.Api.Webhooks do
  @moduledoc """
  Webhook endpoints on the server API (WH-2, WH-12, WH-16, WH-40, WH-45): list, create (`201`), read, change with a JSON Merge Patch under an optional `If-Match`, archive, rotate the signing key, and read the endpoint versions. An endpoint belongs to the environment of the credential, which is never read from the request and never changes. Its subscription is an explicit selection of event types, `*` being an explicit choice of all: an endpoint of use `relay_events` names types of Relay's catalog (`Relay.EventCatalog`), one of use `destination` the tenant's own types. Every HTTPS address follows the registration rules; a credential is only ever the identifier of a registered secret reference.

  A signing key is made before the request's transaction, because that reaches the key store (`prepare_create/2`, `prepare_rotation/3`), and so is the early DNS check of an address (`prepare_update/1`, WH-40 (4)); the endpoint and its audit record are then written inside it. The secret of a `v1` key is in the answer of the request that made it and nowhere else.
  """

  alias Relay.Api.Duration
  alias Relay.Api.Gate
  alias Relay.Api.Page
  alias Relay.Api.Pagination
  alias Relay.Api.Views
  alias Relay.Scope

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @uses ~w(relay_events destination)
  @states ~w(active paused disabled archived)
  @addresses ~w(url token_url queue_url endpoint)
  @plain ~w(event_types snapshot description state auto_disable max_concurrency)
  @wait %{
    min: Relay.Limits.seconds!(["webhook", "retry_schedule", "wait", "min"]),
    max: Relay.Limits.seconds!(["webhook", "retry_schedule", "wait", "max"])
  }
  @window %{
    min: Relay.Limits.seconds!(["webhook", "retry_schedule", "window", "min"]),
    max: Relay.Limits.seconds!(["webhook", "retry_schedule", "window", "max"])
  }

  # WH-2
  # WH-5
  @doc "The API view of an endpoint as `Relay.Webhooks.endpoint/1` reads it."
  @spec view(map()) :: map()
  def view(e) do
    %{
      "object" => "webhook_endpoint",
      "id" => Views.id("whe", e["id"]),
      "environment" => e["environment"],
      "use" => e["use_kind"],
      "consumer" => e["consumer_key"],
      "consumer_id" => Views.id("whc", e["consumer_id"]),
      "destination" => destination_view(e),
      "event_types" => e["event_types"],
      "signature_scheme" => e["signature_scheme"],
      "signing_keys" => Enum.map(e["keys"], &key_view/1),
      "snapshot" => e["snapshot"],
      "payload_version" => e["payload_version"],
      "description" => e["description"],
      "state" => e["state"],
      "disabled_reason" => e["disabled_reason"],
      "managed_by" => e["managed_by"],
      "product" => e["product"],
      "auto_disable" => e["auto_disable"],
      "retry_schedule" => e["retry_schedule"] && Enum.map(e["retry_schedule"], &iso/1),
      "max_concurrency" => e["max_concurrency"],
      "rate_limit_per_second" => e["rate_per_second"],
      "version" => e["current_version"],
      "created_at" => e["created_at"],
      "updated_at" => e["updated_at"],
      "archived_at" => e["archived_at"]
    }
  end

  defp destination_view(%{"credential_ref_id" => nil, "destination" => destination}),
    do: destination

  defp destination_view(%{"credential_ref_id" => id, "destination" => destination}),
    do: Map.put(destination, "credential_ref_id", Views.id("sec", id))

  defp key_view(k) do
    %{
      "id" => Views.id("whk", k["id"]),
      "scheme" => k["scheme"],
      "state" => k["state"],
      "public_key" => Relay.Webhooks.public_key(k["public_key"]),
      "activated_at" => k["activated_at"],
      "expires_at" => k["expires_at"]
    }
  end

  # WH-12
  @doc "The API view of an endpoint version."
  @spec version_view(map()) :: map()
  def version_view(v) do
    %{
      "object" => "webhook_endpoint_version",
      "endpoint_id" => Views.id("whe", v["endpoint_id"]),
      "version" => v["version"],
      "snapshot" => v["snapshot"],
      "payload_version" => v["payload_version"],
      "created_at" => v["created_at"]
    }
  end

  @doc "The ETag header of a version."
  @spec etag(pos_integer()) :: {String.t(), String.t()}
  def etag(version), do: {"etag", ~s("#{version}")}

  # WH-22
  @doc "Writes seconds as an ISO 8601 duration of hours, minutes and seconds."
  @spec iso(non_neg_integer()) :: String.t()
  def iso(0), do: "PT0S"

  def iso(seconds) when is_integer(seconds) and seconds > 0 do
    minutes = seconds |> rem(3600) |> div(60)
    parts = [{div(seconds, 3600), "H"}, {minutes, "M"}, {rem(seconds, 60), "S"}]
    "PT" <> Enum.map_join(parts, fn {n, unit} -> if n > 0, do: "#{n}#{unit}", else: "" end)
  end

  # API-56
  @doc "Reads the `use`, `state` and `consumer_id` filters of a list request."
  @spec filters(map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def filters(query) do
    with {:ok, usage} <- one_of(query, "use", @uses),
         {:ok, state} <- one_of(query, "state", @states),
         {:ok, consumer_id} <- consumer_filter(Map.get(query, "consumer_id")) do
      {:ok, %{use: usage, state: state, consumer_id: consumer_id}}
    end
  end

  defp one_of(query, name, allowed) do
    value = Map.get(query, name)

    if value == nil or value in allowed,
      do: {:ok, value},
      else: {:error, Gate.field_error("/" <> name, "unsupported_value", "unknown " <> name)}
  end

  defp consumer_filter(nil), do: {:ok, nil}

  defp consumer_filter(text) do
    case Relay.ExternalId.decode(text, ["whc"]) do
      {:ok, id} -> {:ok, id}
      {:error, _error} -> {:error, Gate.field_error("/consumer_id", "invalid_format", "bad id")}
    end
  end

  # WH-16
  # WH-22
  # WH-40
  # WH-5
  @doc "Checks an endpoint creation and, for an `https` endpoint, makes its signing key; runs outside any transaction."
  @spec prepare_create(Scope.t(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def prepare_create(%Scope{} = scope, body) do
    destination = body["destination"]
    kind = destination["kind"]

    with :ok <- consumer_rule(body),
         :ok <- scheme_rule(body, kind),
         :ok <- destination_rules(destination, "/destination"),
         :ok <- resolved(destination, "/destination"),
         :ok <- subscription(body["use"], body["event_types"]),
         {:ok, schedule} <- schedule(body["retry_schedule"]),
         {:ok, credential_ref_id} <- credential(destination),
         {:ok, key} <- first_key(scope, kind, Map.get(body, "signature_scheme", "v1a")) do
      {:ok,
       %{
         key: key,
         attrs: %{
           use: body["use"],
           consumer: body["consumer"],
           kind: kind,
           url: destination["url"],
           destination: Map.delete(destination, "credential_ref_id"),
           credential_ref_id: credential_ref_id,
           event_types: body["event_types"],
           signature_scheme: key && key.scheme,
           snapshot: Map.get(body, "snapshot", []),
           description: body["description"],
           settings: %{
             "auto_disable" => Map.get(body, "auto_disable", true),
             "retry_schedule" => schedule,
             "max_concurrency" => body["max_concurrency"],
             "rate_per_second" => body["rate_limit_per_second"]
           }
         }
       }}
    end
  end

  defp consumer_rule(%{"use" => "destination"} = body) when not is_map_key(body, "consumer"),
    do: {:error, Gate.field_error("/consumer", "required", "a destination names its consumer")}

  defp consumer_rule(%{"use" => "relay_events", "consumer" => _key}),
    do: {:error, Gate.field_error("/consumer", "not_allowed", "relay_events has no consumer")}

  defp consumer_rule(_body), do: :ok

  defp scheme_rule(%{"signature_scheme" => _scheme}, kind) when kind != "https",
    do: {:error, Gate.field_error("/signature_scheme", "not_allowed", "only https is signed")}

  defp scheme_rule(_body, _kind), do: :ok

  defp first_key(_scope, kind, _scheme) when kind != "https", do: {:ok, nil}
  defp first_key(scope, "https", scheme), do: new_key(scope, scheme)

  defp new_key(scope, scheme) do
    case Relay.Webhooks.new_key(scope, scheme) do
      {:ok, key} -> {:ok, key}
      {:error, _error} -> {:error, unavailable()}
    end
  end

  # WH-40
  # WH-43
  defp destination_rules(destination, pointer) do
    with :ok <- addresses(destination, pointer), do: auth_rule(destination, pointer)
  end

  defp addresses(destination, pointer) do
    refused =
      for name <- @addresses,
          url = destination[name],
          is_binary(url),
          {:error, reason} <- [Relay.Webhooks.check_address(url)] do
        detail = Relay.Webhooks.explain_address(reason)
        %{pointer: pointer <> "/" <> name, code: "not_allowed", detail: detail}
      end

    details = %{errors: refused}
    error = Relay.Error.new(:webhook_endpoint_url_not_allowed, "address not allowed", details)
    if refused == [], do: :ok, else: {:error, error}
  end

  # WH-40 (4)
  defp resolved(destination, pointer) do
    refused =
      for name <- @addresses,
          url = destination[name],
          is_binary(url),
          {:ok, [address | _rest]} <- [Relay.Webhooks.blocked_addresses(url)] do
        detail = "the host resolves to the blocked address " <> address
        %{pointer: pointer <> "/" <> name, code: "not_allowed", detail: detail}
      end

    details = %{errors: refused}
    error = Relay.Error.new(:webhook_endpoint_url_not_allowed, "address not allowed", details)
    if refused == [], do: :ok, else: {:error, error}
  end

  # WH-40 (4)
  @doc "The early DNS check of an endpoint change that names a new destination; runs outside any transaction."
  @spec prepare_update(map()) :: :ok | {:error, Relay.Error.t()}
  def prepare_update(%{"destination" => %{} = destination}),
    do: resolved(destination, "/destination")

  def prepare_update(_body), do: :ok

  defp auth_rule(%{"kind" => "https"} = destination, pointer) do
    absent =
      case Map.get(destination, "auth", "none") do
        "none" -> []
        "mtls" -> missing(destination, ["client_certificate", "credential_ref_id"])
        _oauth2 -> missing(destination, ["token_url", "client_id", "credential_ref_id"])
      end

    required(absent, pointer)
  end

  defp auth_rule(_destination, _pointer), do: :ok

  defp missing(destination, names), do: Enum.reject(names, &is_map_key(destination, &1))

  defp required([], _pointer), do: :ok

  defp required(names, pointer) do
    errors =
      for name <- names do
        %{pointer: pointer <> "/" <> name, code: "required", detail: "the auth needs " <> name}
      end

    {:error, Relay.Error.new(:validation_failed, "incomplete destination", %{errors: errors})}
  end

  # WH-16
  # WH-53
  defp subscription("relay_events", event_types) do
    errors =
      for {name, index} <- Enum.with_index(event_types),
          name != "*" and not Relay.EventCatalog.delivered?(name) do
        detail = "not an event type of the catalog"
        %{pointer: "/event_types/#{index}", code: "not_found", detail: detail}
      end

    if errors == [],
      do: :ok,
      else: {:error, Relay.Error.new(:validation_failed, "unknown event type", %{errors: errors})}
  end

  defp subscription(_destination, _event_types), do: :ok

  # WH-22
  # WH-52
  defp schedule(nil), do: {:ok, nil}

  defp schedule(waits) do
    seconds = Enum.map(waits, &seconds/1)

    cond do
      Enum.any?(seconds, &is_nil/1) ->
        {:error, schedule_error("invalid_format", "a wait is not a duration")}

      Enum.any?(tl(seconds), &(&1 < @wait.min)) or Enum.any?(seconds, &(&1 > @wait.max)) ->
        {:error, schedule_error("not_allowed", "a wait is outside the allowed range")}

      length(seconds) > 1 and Enum.sum(seconds) not in @window.min..@window.max ->
        {:error, schedule_error("not_allowed", "the waits add up outside the allowed window")}

      true ->
        {:ok, seconds}
    end
  end

  defp seconds(text) do
    case Duration.to_ms(text) do
      {:ok, ms} when rem(ms, 1000) == 0 -> div(ms, 1000)
      _other -> nil
    end
  end

  defp schedule_error(code, detail), do: Gate.field_error("/retry_schedule", code, detail)

  defp credential(%{"credential_ref_id" => text}) do
    case Relay.ExternalId.decode(text, ["sec"]) do
      {:ok, id} -> {:ok, id}
      {:error, _error} -> {:error, no_credential()}
    end
  end

  defp credential(_destination), do: {:ok, nil}

  # WH-2
  # WH-45
  # API-55
  @doc "Creates a prepared endpoint inside the request's transaction, in the environment of `scope`, with its payload version pinned to `api_version`; `201` with the endpoint and, for a `v1` key, its secret."
  @spec create(Scope.t(), map(), String.t(), Relay.Actor.t()) :: answer()
  def create(%Scope{} = scope, %{attrs: attrs, key: key}, api_version, actor) do
    attrs = Map.put(attrs, :payload_version, api_version)
    digest = Gate.digest(scope, "webhook_endpoint.created", attrs.destination["kind"])

    case Relay.Webhooks.endpoint_create(attrs, key, digest, actor) do
      {:created, id} ->
        endpoint = Relay.Webhooks.endpoint(id)
        location = {"location", "/v1/webhook_endpoints/" <> Views.id("whe", id)}
        {:ok, {201, [etag(endpoint["version"]), location], secret_view(endpoint, key, nil)}}

      {refused, _id} ->
        {:error, refused(refused)}
    end
  end

  defp secret_view(endpoint, key, previous_expires_at) do
    secret = key && key.secret && Relay.Redacted.expose(key.secret)

    endpoint
    |> view()
    |> Map.merge(%{"secret" => secret, "previous_key_expires_at" => previous_expires_at})
  end

  defp refused(limit) when limit in [:tenant_limit_reached, :consumer_limit_reached],
    do: Relay.Error.new(:webhook_endpoint_limit_reached, "the endpoint limit is reached")

  defp refused(:consumer_not_found),
    do: Gate.field_error("/consumer", "not_found", "no consumer has this key")

  defp refused(:consumer_archived),
    do: Relay.Error.new(:webhook_consumer_archived, "the consumer is archived")

  defp refused(:credential_not_found), do: no_credential()

  defp refused(:event_type_not_found),
    do: Gate.field_error("/event_types", "not_found", "not an event type of the tenant")

  defp refused(:tenant_inactive),
    do: Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")

  defp refused(:version_conflict),
    do: Relay.Error.new(:precondition_failed, "the endpoint changed; read it again")

  defp refused(:archived), do: archived()
  defp refused(:managed), do: managed()
  defp refused(:not_found), do: not_found()

  defp refused(:invalid_state),
    do: Relay.Error.new(:webhook_endpoint_state_conflict, "a paused endpoint is resumed")

  defp refused(:not_signed),
    do: Relay.Error.new(:webhook_endpoint_not_signed, "only an https endpoint is signed")

  # WH-2
  @doc "Reads an endpoint."
  @spec get(Scope.t(), Relay.Id.t()) :: answer()
  def get(%Scope{} = scope, id) do
    case Relay.Webhooks.get_endpoint(scope, id) do
      {:ok, %{} = endpoint} -> {:ok, {200, [etag(endpoint["version"])], view(endpoint)}}
      {:ok, nil} -> {:error, not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # WH-2
  # API-56
  @doc "Lists endpoints, newest first."
  @spec list(Scope.t(), map(), Pagination.page(), String.t()) :: answer()
  def list(%Scope{} = scope, filters, page, endpoint) do
    case Relay.Webhooks.list_endpoints(scope, filters, page.cursor, page.limit) do
      {:ok, rows} ->
        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &view/1, &position/1),
             do: {:ok, {200, [], body}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # WH-12
  # WH-16
  # WH-40
  # WH-48
  @doc "Applies a JSON Merge Patch to an endpoint inside the request's transaction; `expected_version` is the version an `If-Match` named, or `nil`. The destination keeps its kind."
  @spec update(Scope.t(), Relay.Id.t(), map(), pos_integer() | nil, Relay.Actor.t()) :: answer()
  def update(%Scope{} = scope, id, body, expected_version, actor) do
    with {:ok, current} <- found(Relay.Webhooks.endpoint(id)),
         {:ok, changes} <- changes(current, body) do
      digest = Gate.digest(scope, "webhook_endpoint.updated", Relay.Id.to_string(id))

      case Relay.Webhooks.endpoint_update(id, expected_version, changes, digest, actor) do
        {result, version} when result in [:updated, :unchanged] ->
          recovered(result, current, changes, id)
          {:ok, {200, [etag(version)], view(Relay.Webhooks.endpoint(id))}}

        {refused, _version} ->
          {:error, refused(refused)}
      end
    end
  end

  # WH-34
  defp recovered(:updated, %{"state" => "disabled"}, %{"state" => "active"}, id),
    do: Relay.Webhooks.endpoint_recovered(id)

  defp recovered(_result, _current, _changes, _id), do: :ok

  defp found(nil), do: {:error, not_found()}
  defp found(%{} = endpoint), do: {:ok, endpoint}

  defp changes(current, body) do
    with {:ok, destination} <- destination_change(current, body),
         :ok <- subscription_change(current, body),
         {:ok, schedule} <- schedule_change(body) do
      {:ok,
       body
       |> Map.take(@plain)
       |> Map.merge(destination)
       |> Map.merge(schedule)
       |> put_renamed(body, "rate_limit_per_second", "rate_per_second")}
    end
  end

  defp put_renamed(changes, body, from, to) do
    case Map.fetch(body, from) do
      {:ok, value} -> Map.put(changes, to, value)
      :error -> changes
    end
  end

  defp destination_change(current, %{"destination" => destination}) do
    with :ok <- same_kind(current, destination),
         :ok <- destination_rules(destination, "/destination"),
         {:ok, credential_ref_id} <- credential(destination) do
      {:ok,
       %{
         "destination" => Map.delete(destination, "credential_ref_id"),
         "url" => destination["url"],
         "credential_ref_id" => credential_ref_id && Relay.Id.to_string(credential_ref_id)
       }}
    end
  end

  defp destination_change(_current, _body), do: {:ok, %{}}

  defp same_kind(%{"kind" => kind}, %{"kind" => kind}), do: :ok

  defp same_kind(_current, _destination),
    do: {:error, Gate.field_error("/destination/kind", "not_allowed", "the kind never changes")}

  defp subscription_change(current, %{"event_types" => event_types}),
    do: subscription(current["use_kind"], event_types)

  defp subscription_change(_current, _body), do: :ok

  defp schedule_change(%{"retry_schedule" => waits}) do
    with {:ok, seconds} <- schedule(waits), do: {:ok, %{"retry_schedule" => seconds}}
  end

  defp schedule_change(_body), do: {:ok, %{}}

  # WH-48
  @doc "Archives an endpoint inside the request's transaction; archiving an archived endpoint returns it."
  @spec archive(Scope.t(), Relay.Id.t(), Relay.Actor.t()) :: answer()
  def archive(%Scope{} = scope, id, actor) do
    digest = Gate.digest(scope, "webhook_endpoint.archived", Relay.Id.to_string(id))

    case Relay.Webhooks.endpoint_archive(id, digest, actor) do
      {result, _version} when result in [:archived, :already_archived] ->
        {:ok, {200, [], view(Relay.Webhooks.endpoint(id))}}

      {refused, _version} ->
        {:error, refused(refused)}
    end
  end

  # WH-31
  # WH-48
  @doc "Pauses an endpoint inside the request's transaction: its messages are held, not dropped. Pausing a paused endpoint returns it."
  @spec pause(Scope.t(), Relay.Id.t(), Relay.Actor.t()) :: answer()
  def pause(%Scope{} = scope, id, actor),
    do: switched(Relay.Webhooks.endpoint_pause(id, digest(scope, id), actor), id)

  # WH-31
  # WH-48
  @doc "Resumes a paused endpoint inside the request's transaction; its held messages are released within the endpoint's limits. Resuming an active endpoint returns it."
  @spec resume(Scope.t(), Relay.Id.t(), Relay.Actor.t()) :: answer()
  def resume(%Scope{} = scope, id, actor),
    do: switched(Relay.Webhooks.endpoint_resume(id, digest(scope, id), actor), id)

  defp digest(scope, id),
    do: Gate.digest(scope, "webhook_endpoint.updated", Relay.Id.to_string(id))

  defp switched({result, _version}, id) when result in [:changed, :unchanged] do
    endpoint = Relay.Webhooks.endpoint(id)
    {:ok, {200, [etag(endpoint["version"])], view(endpoint)}}
  end

  defp switched({refused, _version}, _id), do: {:error, refused(refused)}

  # WH-45 (3)
  @doc "Sends the test event of an endpoint inside the request's transaction: `202` with its message, which is attempted once whatever the endpoint subscribes to."
  @spec test(Scope.t(), Relay.Id.t(), map() | nil) :: answer()
  def test(%Scope{}, id, body) do
    with {:ok, endpoint} <- found(Relay.Webhooks.endpoint(id)),
         :ok <- testable(endpoint, body || %{}),
         %{} = message <- Relay.Webhooks.test_event(endpoint) do
      {:ok, {202, [], message_view(message)}}
    else
      nil -> {:error, archived()}
      {:error, error} -> {:error, error}
    end
  end

  defp testable(%{"state" => "archived"}, _body), do: {:error, archived()}

  defp testable(%{"state" => state}, _body) when state != "active",
    do: {:error, refused(:invalid_state)}

  defp testable(_endpoint, %{"event_type" => type}) when type != "webhook_endpoint.tested",
    do: {:error, Gate.field_error("/event_type", "not_found", "the event type has no example")}

  defp testable(_endpoint, _body), do: :ok

  # WH-2
  @doc "The API view of a message as `Relay.Webhooks.message/1` reads it, inside the caller's scoped transaction."
  @spec message_view(map()) :: map()
  def message_view(m) do
    %{
      "object" => "webhook_message",
      "id" => Views.id("whm", m["id"]),
      "endpoint_id" => Views.id("whe", m["endpoint_id"]),
      "endpoint_version" => m["endpoint_version"],
      "event_id" => Relay.Webhooks.webhook_id(m),
      "event_type" => m["event_type"],
      "origin" => m["origin"],
      "state" => m["state"],
      "hold_reason" => m["hold_reason"],
      "reason" => m["reason"],
      "attempt_count" => m["total_attempt_count"],
      "next_attempt_at" => m["next_attempt_at"],
      "last_attempt_at" => m["last_attempt_at"],
      "last_response_status" => m["last_response_status"],
      "delivered_at" => m["delivered_at"],
      "expires_at" => m["expires_at"],
      "created_at" => m["created_at"],
      "updated_at" => m["updated_at"]
    }
  end

  # WH-39
  @doc "Reads the health of an endpoint."
  @spec health(Scope.t(), Relay.Id.t()) :: answer()
  def health(%Scope{} = scope, id) do
    case Relay.Webhooks.endpoint_health(scope, id) do
      {:ok, %{} = health} -> {:ok, {200, [], health_view(health)}}
      {:ok, nil} -> {:error, not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp health_view(%{endpoint: endpoint, health: health, statistics: statistics} = h) do
    totals = statistics.totals
    attempts = totals["succeeded"] + totals["failed"]

    %{
      "object" => "webhook_endpoint_health",
      "endpoint_id" => Views.id("whe", endpoint["id"]),
      "state" => endpoint["state"],
      "disabled_reason" => endpoint["disabled_reason"],
      "window" => iso(h.window_s),
      "succeeded" => totals["succeeded"],
      "failed" => totals["failed"],
      "success_rate_bp" => if(attempts > 0, do: div(totals["succeeded"] * 10_000, attempts)),
      "latency_ms" => latency(totals),
      "last_success_at" => health["last_success_at"],
      "last_failure_at" => health["last_failure_at"],
      "failing_since" => health["failing_since"],
      "disable_at" => h.disable_at,
      "backlog" => %{
        "waiting" => h.backlog["waiting"],
        "held" => h.backlog["held"],
        "oldest_at" => h.backlog["oldest_at"]
      },
      "breaker" => %{
        "state" => health["breaker_state"],
        "opened_at" => health["breaker_opened_at"],
        "retry_at" => health["breaker_retry_at"]
      },
      "recent_failures" => Enum.map(statistics.failures, &Map.take(&1, ~w(code count last_at)))
    }
  end

  defp latency(%{"p50" => nil}), do: nil
  defp latency(totals), do: Map.take(totals, ["p50", "p95", "p99"])

  # WH-6
  @doc "Checks a key rotation and makes the new key, outside any transaction: the scheme is the request's or the endpoint's own, the overlap the request's or the default."
  @spec prepare_rotation(Scope.t(), Relay.Id.t(), map() | nil) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def prepare_rotation(%Scope{} = scope, id, body) do
    body = body || %{}

    with {:ok, endpoint} <- rotatable(Relay.Webhooks.get_endpoint(scope, id)),
         {:ok, overlap_s} <- overlap(body["overlap"]),
         scheme = Map.get(body, "signature_scheme", endpoint["signature_scheme"]),
         {:ok, key} <- new_key(scope, scheme) do
      {:ok, %{key: key, overlap_s: overlap_s}}
    end
  end

  defp rotatable({:ok, nil}), do: {:error, not_found()}
  defp rotatable({:error, _reason}), do: {:error, unavailable()}
  defp rotatable({:ok, %{"state" => "archived"}}), do: {:error, archived()}
  defp rotatable({:ok, %{"managed_by" => "product"}}), do: {:error, managed()}
  defp rotatable({:ok, %{"kind" => "https"} = endpoint}), do: {:ok, endpoint}
  defp rotatable({:ok, _endpoint}), do: {:error, refused(:not_signed)}

  defp overlap(nil), do: {:ok, Relay.Webhooks.key_overlap().default}

  defp overlap(text) do
    max = Relay.Webhooks.key_overlap().max

    case seconds(text) do
      seconds when is_integer(seconds) and seconds <= max -> {:ok, seconds}
      _other -> {:error, Gate.field_error("/overlap", "not_allowed", "the overlap is too long")}
    end
  end

  # WH-6
  # WH-48
  @doc "Rotates the signing key of an endpoint to a prepared key inside the request's transaction; `200` with the endpoint, the secret of a `v1` key and when the previous key stops."
  @spec rotate(Scope.t(), Relay.Id.t(), map(), Relay.Actor.t()) :: answer()
  def rotate(%Scope{} = scope, id, %{key: key, overlap_s: overlap_s}, actor) do
    digest = Gate.digest(scope, "webhook_endpoint.key_rotated", Relay.Id.to_string(key.id))

    case Relay.Webhooks.endpoint_key_rotate(id, key, overlap_s, digest, actor) do
      {:rotated, _previous_id, previous_expires_at} ->
        {:ok, {200, [], secret_view(Relay.Webhooks.endpoint(id), key, previous_expires_at)}}

      {refused, _previous_id, _previous_expires_at} ->
        {:error, refused(refused)}
    end
  end

  # WH-12
  @doc "Reads one version of an endpoint."
  @spec get_version(Scope.t(), Relay.Id.t(), pos_integer()) :: answer()
  def get_version(%Scope{} = scope, id, version) do
    case Relay.Webhooks.get_endpoint_version(scope, id, version) do
      {:ok, %{} = row} -> {:ok, {200, [], version_view(row)}}
      {:ok, nil} -> {:error, not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # WH-12
  # API-56
  @doc "Lists the versions of an endpoint, newest first."
  @spec versions(Scope.t(), Relay.Id.t(), Pagination.page(), String.t()) :: answer()
  def versions(%Scope{} = scope, id, page, endpoint) do
    position = &{DateTime.from_unix!(&1["version"], :microsecond), &1["endpoint_id"]}

    case Relay.Webhooks.list_endpoint_versions(scope, id, page.cursor, page.limit) do
      {:ok, :not_found} ->
        {:error, not_found()}

      {:ok, rows} ->
        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &version_view/1, position),
             do: {:ok, {200, [], body}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  defp position(row), do: {row["cursor_at"], row["id"]}

  @doc "The error of an unknown endpoint identifier or version."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:webhook_endpoint_not_found, "no endpoint has this id")

  defp archived, do: Relay.Error.new(:webhook_endpoint_archived, "the endpoint is archived")
  defp managed, do: Relay.Error.new(:webhook_endpoint_managed, "a product manages the endpoint")

  defp no_credential,
    do: Relay.Error.new(:webhook_credential_not_found, "no active secret reference has this id")

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
