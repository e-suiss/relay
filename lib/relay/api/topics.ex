defmodule Relay.Api.Topics do
  @moduledoc """
  Topics and subscriptions on the server API (WF-51, API-69, API-75): list, create (`201`), read and archive a topic; list, add in bulk and remove the subscriptions of a topic; and list the topics a subscriber is subscribed to. A topic has at most one parent, which itself has none, so the hierarchy is at most two levels. Subscriptions name subscribers by their external identifiers only; there is no attribute query (WF-54, E-67). Removing a subscription keeps it as `removed`, and adding many is all or nothing: one unknown subscriber refuses the request with its pointer.
  """

  alias Relay.Api.Page
  alias Relay.Api.Pagination
  alias Relay.Api.Views
  alias Relay.Scope

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # WF-51
  @doc "The API view of a topic row."
  @spec view(map()) :: map()
  def view(t) do
    %{
      "object" => "topic",
      "id" => Views.id("top", t["id"]),
      "key" => t["key"],
      "parent" => t["parent_key"],
      "state" => t["state"],
      "version" => t["version"],
      "created_at" => t["created_at"],
      "updated_at" => t["updated_at"],
      "archived_at" => t["archived_at"]
    }
  end

  # WF-51
  @doc "The API view of a subscription row with its subscriber's external identifier."
  @spec subscription_view(map(), String.t() | nil) :: map()
  def subscription_view(s, external_id) do
    %{
      "object" => "topic_subscription",
      "id" => Views.id("tsb", s["id"]),
      "topic" => s["topic_key"],
      "subscriber_id" => external_id,
      "state" => s["state"],
      "created_at" => s["created_at"],
      "removed_at" => s["removed_at"]
    }
  end

  # WF-51
  @doc "Creates a topic inside the request's transaction; `201` with its view."
  @spec create(Scope.t(), map(), Relay.Actor.t()) :: answer()
  def create(%Scope{} = scope, body, actor) do
    key = body["key"]
    digest = digest(scope, "topic.created", key)

    case Relay.Topics.create(key, body["parent"], digest, actor) do
      {:created, _id, _version} ->
        {:ok, {201, [{"location", "/v1/topics/" <> key}], view(Relay.Topics.fetch(key))}}

      {:key_conflict, _id, _version} ->
        {:error, Relay.Error.new(:resource_conflict, "a topic with this key exists")}

      {:parent_not_found, _id, _version} ->
        {:error, parent_error("not_found", "no topic has this key")}

      {:too_deep, _id, _version} ->
        {:error, parent_error("not_allowed", "a child topic cannot be a parent")}

      {:parent_archived, _id, _version} ->
        {:error, archived()}

      {:tenant_inactive, _id, _version} ->
        {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}
    end
  end

  defp parent_error(code, detail) do
    error = %{pointer: "/parent", code: code, detail: detail}
    message = "the topic breaks a field rule"
    Relay.Error.new(:validation_failed, message, %{errors: [error]})
  end

  # WF-51
  @doc "Reads a topic."
  @spec get(Scope.t(), String.t()) :: answer()
  def get(%Scope{} = scope, key) do
    case Relay.Topics.get(scope, key) do
      {:ok, %{} = topic} -> {:ok, {200, [], view(topic)}}
      {:ok, nil} -> {:error, not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # WF-51
  # API-56
  @doc "Lists topics."
  @spec list(Scope.t(), Pagination.page(), String.t()) :: answer()
  def list(%Scope{} = scope, page, endpoint) do
    case Relay.Topics.list(scope, page.cursor, page.limit) do
      {:ok, rows} ->
        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &view/1, &position/1),
             do: {:ok, {200, [], body}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # WF-51
  @doc "Archives a topic inside the request's transaction; archiving an archived topic returns it. An archived topic is refused as a send target and takes no new subscription."
  @spec archive(Scope.t(), String.t(), Relay.Actor.t()) :: answer()
  def archive(%Scope{} = scope, key, actor) do
    case Relay.Topics.archive(key, digest(scope, "topic.archived", key), actor) do
      {result, _version} when result in [:archived, :already_archived] ->
        {:ok, {200, [], view(Relay.Topics.fetch(key))}}

      {:not_found, _version} ->
        {:error, not_found()}
    end
  end

  # WF-51
  @doc "Prepares adding or removing subscribers of a topic outside any transaction: the blind indexes of their external identifiers."
  @spec prepare_change(Scope.t(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def prepare_change(%Scope{} = scope, %{"subscribers" => external_ids}) do
    case Relay.Subscribers.indexes(scope, external_ids) do
      {:ok, bidxs} -> {:ok, %{external_ids: external_ids, bidxs: bidxs}}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # WF-51
  # WF-52
  @doc "Subscribes prepared subscribers to a topic inside the request's transaction; `200` with every named subscriber's subscription, new or already active. An unknown subscriber refuses the whole request."
  @spec subscribe(Scope.t(), String.t(), map(), Relay.Actor.t()) :: answer()
  def subscribe(%Scope{} = scope, key, prepared, actor) do
    digest = digest(scope, "topic.subscribed", ref(key, prepared))

    case Relay.Topics.subscribe(key, prepared.bidxs, digest, actor) do
      {:ok, rows} -> changed(rows, prepared.external_ids)
      {:error, :topic_not_found} -> {:error, not_found()}
      {:error, :topic_archived} -> {:error, archived()}
      {:error, :tenant_inactive} -> {:error, suspended()}
    end
  end

  # WF-51
  @doc "Unsubscribes prepared subscribers from a topic inside the request's transaction; the rows are kept as `removed`. `200` with the removed subscription of every named subscriber that was ever subscribed, removed now or before. An unknown subscriber refuses the whole request."
  @spec unsubscribe(Scope.t(), String.t(), map(), Relay.Actor.t()) :: answer()
  def unsubscribe(%Scope{} = scope, key, prepared, actor) do
    digest = digest(scope, "topic.unsubscribed", ref(key, prepared))

    case Relay.Topics.unsubscribe(key, prepared.bidxs, digest, actor) do
      {:ok, rows} -> changed(rows, prepared.external_ids)
      {:error, :topic_not_found} -> {:error, not_found()}
    end
  end

  defp ref(key, prepared), do: key <> ":" <> Enum.join(prepared.external_ids, ",")

  defp changed(rows, external_ids) do
    errors = for {n, :recipient_not_found, _id, _sub} <- rows, do: unknown_subscriber(n)

    if errors == [] do
      {:ok, {200, [], Pagination.envelope(listed(rows, external_ids), false, nil, nil)}}
    else
      message = "a subscriber does not exist"
      {:error, Relay.Error.new(:recipient_not_found, message, %{errors: errors})}
    end
  end

  defp listed(rows, external_ids) do
    names = external_ids |> Enum.with_index(1) |> Map.new(fn {id, n} -> {n, id} end)
    firsts = rows |> Enum.reject(&is_nil(elem(&1, 3))) |> Enum.uniq_by(&elem(&1, 3))
    stored = firsts |> Enum.map(&elem(&1, 3)) |> Relay.Topics.subscriptions_by_id()
    by_id = Map.new(stored, &{&1["id"], &1})

    for {n, _result, _recipient_id, id} <- firsts,
        do: subscription_view(Map.fetch!(by_id, id), names[n])
  end

  defp unknown_subscriber(n),
    do: %{pointer: "/subscribers/#{n - 1}", code: "not_found", detail: "unknown subscriber"}

  # WF-51
  # API-56
  @doc "Lists the active subscriptions of a topic."
  @spec subscriptions(Scope.t(), String.t(), Pagination.page(), String.t()) :: answer()
  def subscriptions(%Scope{} = scope, key, page, endpoint) do
    with {:ok, rows} <- topic_subscriptions(scope, key, page),
         {:ok, names} <- names(scope, rows),
         view = &subscription_view(&1, names[&1["recipient_id"]]),
         {:ok, body} <- Page.envelope(rows, page, scope, endpoint, view, &position/1),
         do: {:ok, {200, [], body}}
  end

  defp topic_subscriptions(scope, key, page) do
    case Relay.Topics.subscriptions(scope, key, page.cursor, page.limit) do
      {:ok, :not_found} -> {:error, not_found()}
      {:ok, rows} -> {:ok, rows}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp names(_scope, []), do: {:ok, %{}}

  defp names(scope, rows) do
    ids = rows |> Enum.map(& &1["recipient_id"]) |> Enum.uniq()

    case Relay.Subscribers.external_ids(scope, ids) do
      {:ok, names} -> {:ok, names}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # WF-51
  # API-56
  @doc "Lists the active subscriptions of a subscriber, by its external identifier."
  @spec subscriber_subscriptions(Scope.t(), String.t(), Pagination.page(), String.t()) ::
          answer()
  def subscriber_subscriptions(%Scope{} = scope, external_id, page, endpoint) do
    view = &subscription_view(&1, external_id)

    with {:ok, recipient_id} <- locate(scope, external_id),
         {:ok, rows} <- subscriber_rows(scope, recipient_id, page),
         {:ok, body} <- Page.envelope(rows, page, scope, endpoint, view, &position/1),
         do: {:ok, {200, [], body}}
  end

  defp locate(scope, external_id) do
    case Relay.Subscribers.locate(scope, external_id) do
      {:ok, nil} -> {:error, subscriber_not_found()}
      {:ok, id} -> {:ok, id}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp subscriber_rows(scope, recipient_id, page) do
    case Relay.Topics.subscriber_subscriptions(scope, recipient_id, page.cursor, page.limit) do
      {:ok, rows} -> {:ok, rows}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp position(row), do: {row["cursor_at"], row["id"]}

  defp digest(scope, action, ref) do
    environment = Atom.to_string(scope.environment)
    canonical = Relay.Canonical.encode!([action, {:bytes, scope.tenant_id}, environment, ref])
    :crypto.hash(:sha256, canonical)
  end

  @doc "The error of an unknown topic key."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:topic_not_found, "no topic has this key")

  defp archived, do: Relay.Error.new(:topic_archived, "the topic is archived")

  defp subscriber_not_found,
    do: Relay.Error.new(:subscriber_not_found, "no subscriber has this id")

  defp suspended, do: Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")
  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
