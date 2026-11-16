defmodule Relay.Topics.Audience do
  @moduledoc """
  The pure core of topic fan-out (WF-51 … WF-53, L-31). A send names subscribers directly, topics, or both; a topic reaches its own subscribers and, for a child topic, the subscribers of its active parent. Matching is by topic key only: there is no wildcard, no context condition and no attribute query (WF-53, WF-54, E-67). The frozen recipient set is the direct targets followed by every topic subscriber that is not already named directly, once each, however many paths reach it (WF-52, L-31).
  """

  @type target ::
          {:require, String.t()}
          | {:inbox_only, String.t()}
          | {:implicit, String.t(), map()}
          | {:topic, String.t()}
  @type topic :: %{required(String.t()) => term()}
  @type member :: %{recipient_id: Relay.Id.t(), topic_id: Relay.Id.t(), external_id: String.t()}

  # WF-53
  @doc "The topic targets of a send with their positions in `to`."
  @spec topics([target()]) :: [{String.t(), non_neg_integer()}]
  def topics(targets) do
    for {{:topic, key}, index} <- Enum.with_index(targets), do: {key, index}
  end

  # WF-51
  # WF-53
  @doc "Checks that every named topic exists and is active; returns the topics in request order without repeats, or the field errors of unknown (`:unknown`) or archived (`:archived`) topics."
  @spec check([{String.t(), non_neg_integer()}], [topic()]) ::
          {:ok, [topic()]} | {:error, :unknown | :archived, [map()]}
  def check(named, rows) do
    by_key = Map.new(rows, &{&1["key"], &1})
    unknown = for {key, index} <- named, not Map.has_key?(by_key, key), do: error(index, :unknown)

    archived =
      for {key, index} <- named,
          by_key[key] != nil and by_key[key]["state"] != "active",
          do: error(index, :archived)

    cond do
      unknown != [] -> {:error, :unknown, unknown}
      archived != [] -> {:error, :archived, archived}
      true -> {:ok, named |> Enum.map(&topic(by_key, &1)) |> Enum.uniq_by(& &1["id"])}
    end
  end

  defp topic(by_key, {key, _index}), do: Map.fetch!(by_key, key)

  defp error(index, :unknown),
    do: %{pointer: "/to/#{index}", code: "not_found", detail: "no topic has this key"}

  defp error(index, :archived),
    do: %{pointer: "/to/#{index}", code: "not_allowed", detail: "the topic is archived"}

  # WF-51
  @doc "The topics whose subscribers a topic reaches: itself and, for a child topic, its active parent."
  @spec paths(topic()) :: [Relay.Id.t()]
  def paths(%{"id" => id, "parent_id" => parent, "parent_state" => "active"})
      when parent != nil,
      do: [id, parent]

  def paths(%{"id" => id}), do: [id]

  # WF-52
  @doc "The topics every named topic reaches, in request order without repeats; earlier ones win when a subscriber is reached through several."
  @spec all_paths([topic()]) :: [Relay.Id.t()]
  def all_paths(topics), do: topics |> Enum.flat_map(&paths/1) |> Enum.uniq()

  # WF-52
  # L-31
  @doc "Merges the direct targets with the topic members into the frozen recipient set of at most `max` recipients: the direct targets in order, then each member not named directly as an identity reference. Returns the recipients and the members marked `also_direct`, or `{:too_large, count}`."
  @spec merge([target()], [member()], pos_integer()) ::
          {:ok, [target()], [map()]} | {:too_large, pos_integer()}
  def merge(targets, members, max) do
    direct = Enum.reject(targets, &match?({:topic, _key}, &1))
    named = MapSet.new(direct, &external_id/1)
    marked = Enum.map(members, &Map.put(&1, :also_direct, MapSet.member?(named, &1.external_id)))
    added = for %{also_direct: false, external_id: id} <- marked, do: {:require, id}
    count = length(direct) + length(added)

    if count > max, do: {:too_large, count}, else: {:ok, direct ++ added, marked}
  end

  defp external_id({:require, id}), do: id
  defp external_id({:inbox_only, id}), do: id
  defp external_id({:implicit, id, _fields}), do: id
end
