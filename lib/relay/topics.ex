defmodule Relay.Topics do
  @moduledoc """
  Topics and subscriptions (C-51, WF-51 … WF-55): a topic is a named object that subscribers subscribe to, with at most two levels (a parent such as a project and its children such as tasks). An event sent to a topic reaches the topic's subscribers and, for a child topic, its parent's; the subscriber list is frozen when the send is accepted, so a later subscriber does not get it, and a subscriber reached through several paths, or also named directly, gets one notification (WF-52, L-31). Matching is by key only, with no wildcard, context condition or attribute query (WF-53, WF-54, E-67); a send whose topics reach no subscriber is recorded with its rule (WF-53).

  The frozen audience of a send is recorded per recipient with the topic it was reached through (L-3, F-5). Its source kind is generic, so agent subscriptions and the Access event subscription share it (WF-55). An event carries at most the contract's `event.max_recipients` recipients; a larger topic audience is a campaign (API-35).

  Subscriptions are never deleted: unsubscribing, and erasing the subscriber, keep the row as `removed`.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Subscribers], exports: []

  alias Relay.Actor
  alias Relay.Scope
  alias Relay.Topics.Audience
  alias Relay.Topics.Store

  @max Relay.Limits.fetch!(["event", "max_recipients"])

  @type result(value) :: {:ok, value} | {:error, term()}

  # WF-51
  @doc "Creates a topic, optionally under a parent key, inside the caller's scoped transaction; returns the result, the topic's identifier and its version."
  @spec create(String.t(), String.t() | nil, binary(), Actor.t()) ::
          {atom(), Relay.Id.t() | nil, pos_integer() | nil}
  defdelegate create(key, parent_key, digest, actor), to: Store

  # WF-51
  @doc "Archives a topic inside the caller's scoped transaction; returns the result and its version."
  @spec archive(String.t(), binary(), Actor.t()) :: {atom(), pos_integer() | nil}
  defdelegate archive(key, digest, actor), to: Store

  # WF-51
  @doc "Reads a topic inside the caller's scoped transaction, or `nil`."
  @spec fetch(String.t()) :: map() | nil
  defdelegate fetch(key), to: Store, as: :get

  # WF-51
  @doc "Reads a topic, or `nil`."
  @spec get(Scope.t(), String.t()) :: result(map() | nil)
  def get(%Scope{} = scope, key), do: Store.in_scope(scope, fn _status -> Store.get(key) end)

  # WF-51
  # API-56
  @doc "Lists topics from a decoded cursor; at most `limit + 1` come back."
  @spec list(Scope.t(), map() | nil, pos_integer()) :: result([map()])
  def list(%Scope{} = scope, cursor, limit),
    do: Store.in_scope(scope, fn _status -> Store.topics(cursor, limit) end)

  # WF-51
  @doc "Subscribes the subscribers of blind indexes to a topic inside the caller's scoped transaction; see `Relay.Topics.Store.subscribe/4`."
  @spec subscribe(String.t(), [binary(), ...], binary(), Actor.t()) ::
          {:ok, [{pos_integer(), atom(), Relay.Id.t() | nil, Relay.Id.t() | nil}]}
          | {:error, :topic_not_found | :topic_archived | :tenant_inactive}
  defdelegate subscribe(key, bidxs, digest, actor), to: Store

  # WF-51
  @doc "Ends the subscriptions of the subscribers of blind indexes to a topic inside the caller's scoped transaction, kept as `removed`; see `Relay.Topics.Store.unsubscribe/4`."
  @spec unsubscribe(String.t(), [binary(), ...], binary(), Actor.t()) ::
          {:ok, [{pos_integer(), atom(), Relay.Id.t() | nil, Relay.Id.t() | nil}]}
          | {:error, :topic_not_found}
  defdelegate unsubscribe(key, bidxs, digest, actor), to: Store

  # WF-51
  @doc "Reads subscriptions by identifier inside the caller's scoped transaction."
  @spec subscriptions_by_id([Relay.Id.t()]) :: [map()]
  defdelegate subscriptions_by_id(ids), to: Store

  # WF-51
  # API-56
  @doc "Lists the active subscriptions of a topic from a decoded cursor, or `:not_found` for an unknown topic."
  @spec subscriptions(Scope.t(), String.t(), map() | nil, pos_integer()) ::
          result(:not_found | [map()])
  def subscriptions(%Scope{} = scope, key, cursor, limit) do
    Store.in_scope(scope, fn _status ->
      case Store.get(key) do
        nil -> :not_found
        topic -> Store.topic_subscriptions(topic["id"], cursor, limit)
      end
    end)
  end

  # WF-51
  # API-56
  @doc "Lists the active subscriptions of a subscriber from a decoded cursor."
  @spec subscriber_subscriptions(Scope.t(), Relay.Id.t(), map() | nil, pos_integer()) ::
          result([map()])
  def subscriber_subscriptions(%Scope{} = scope, recipient_id, cursor, limit) do
    read = fn _status -> Store.recipient_subscriptions(recipient_id, cursor, limit) end
    Store.in_scope(scope, read)
  end

  # WF-52
  # WF-53
  # L-31
  # API-35
  @doc """
  Expands the topic targets of a checked send request into its frozen recipient set, outside any transaction. The topics are read once: each named topic must exist and be active, and its subscribers and, for a child topic, its active parent's are frozen as they are now. The result replaces `targets` with the direct targets followed by every subscriber not named directly, as an identity reference, once each; `audience` carries what `record/2` records, `nil` without topics. A send whose topics reach no subscriber is accepted with no topic recipient, and `record/2` records its audience with rule `audience.no_subscribers` (WF-53). More than `event.max_recipients` recipients is `audience_too_large`.
  """
  @spec expand(Scope.t(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def expand(%Scope{} = scope, %{targets: targets} = request) do
    case Audience.topics(targets) do
      [] -> {:ok, Map.put(request, :audience, nil)}
      named -> freeze(scope, request, named)
    end
  end

  # WF-52
  # API-35
  @doc "The recipients a topic reaches now, its active subscribers and, for a child topic, its active parent's, each once in identifier order and at most `limit`, read inside the caller's scoped transaction; `:unknown` or `:archived` for a topic that cannot be sent to."
  @spec recipients(String.t(), pos_integer()) :: {:ok, [Relay.Id.t()]} | :unknown | :archived
  def recipients(key, limit) do
    case Audience.check([{key, 0}], Store.resolve([key])) do
      {:ok, topics} -> {:ok, topics |> Audience.all_paths() |> recipient_ids(limit)}
      {:error, refused, _errors} -> refused
    end
  end

  defp recipient_ids(paths, limit), do: Enum.map(Store.members(paths, limit), &elem(&1, 0))

  defp freeze(scope, request, named) do
    keys = named |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    direct = Enum.count(request.targets, &(not match?({:topic, _key}, &1)))

    with {:ok, {topics, rows}} <- read(scope, named, keys, @max + direct + 1),
         {:ok, members} <- named_members(scope, rows),
         {:ok, targets, marked} <- merged(request.targets, members) do
      audience = %{topic_ids: Enum.map(topics, & &1["id"]), members: marked}
      {:ok, Map.merge(request, %{targets: targets, audience: audience})}
    end
  end

  defp read(scope, named, keys, limit) do
    work = fn _status ->
      case Audience.check(named, Store.resolve(keys)) do
        {:ok, topics} ->
          {:ok, {topics, Store.members(Audience.all_paths(topics), limit)}}

        refused ->
          refused
      end
    end

    case Store.in_scope(scope, work) do
      {:ok, {:ok, frozen}} -> {:ok, frozen}
      {:ok, {:error, :unknown, errors}} -> {:error, unknown(errors)}
      {:ok, {:error, :archived, errors}} -> {:error, archived(errors)}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp named_members(_scope, []), do: {:ok, []}

  defp named_members(scope, rows) do
    case Relay.Subscribers.external_ids(scope, Enum.map(rows, &elem(&1, 0))) do
      {:ok, names} -> {:ok, Enum.flat_map(rows, &member(&1, names))}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp member({recipient_id, topic_id}, names) do
    case Map.get(names, recipient_id) do
      nil -> []
      name -> [%{recipient_id: recipient_id, topic_id: topic_id, external_id: name}]
    end
  end

  defp merged(targets, members) do
    case Audience.merge(targets, members, @max) do
      {:ok, targets, marked} ->
        {:ok, targets, marked}

      {:too_large, count} ->
        message = "the audience is larger than an event's recipients; send it as a campaign"
        {:error, Relay.Error.new(:audience_too_large, message, %{limit: @max, actual: count})}
    end
  end

  # WF-52
  # WF-53
  # F-5
  @doc "Records the frozen audience of an expanded send request as the audience of the event `event_id`, inside the accept transaction; a request without topics records nothing."
  @spec record(map(), Relay.Id.t()) :: :ok
  def record(%{audience: %{topic_ids: topic_ids, members: members}}, event_id) do
    _recorded = Store.record(Relay.Id.generate(), "event", event_id, topic_ids, members)
    :ok
  end

  def record(_request, _event_id), do: :ok

  defp unknown(errors),
    do: Relay.Error.new(:recipient_not_found, "no topic has this key", %{errors: errors})

  defp archived(errors),
    do: Relay.Error.new(:recipient_invalid, "the topic is archived", %{errors: errors})

  defp unavailable,
    do: Relay.Error.new(:service_unavailable, "the topic could not be read", %{retry_after: 1})
end
