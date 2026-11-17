defmodule Relay.Api.Responders do
  @moduledoc """
  Responder references of the API (`%{"kind" => "subscriber" | "agent", "id" => …}`): a subscriber is named by its external identifier, an agent by its `agt_` identifier. A stored reference keeps only the recipient identifier, so an escalation policy and a surface policy hold no external identifier (AG-12, AG-17). Resolving and naming open keys or transactions of their own, so both run outside any transaction.
  """

  alias Relay.Api.Views

  @type ref :: %{required(String.t()) => String.t()}
  @type stored :: %{required(String.t()) => String.t()}
  @type names :: %{String.t() => String.t()}

  # AG-12
  # AG-17
  @doc "Resolves responder references to recipient identifiers: a map from each reference to the identifier of the active subscriber or the existing agent it names, or `nil` when it names none."
  @spec resolve(Relay.Scope.t(), [ref()]) ::
          {:ok, %{ref() => Relay.Id.t() | nil}} | {:error, Relay.Error.t()}
  def resolve(%Relay.Scope{} = scope, refs) when is_list(refs) do
    {agents, subscribers} = refs |> Enum.uniq() |> Enum.split_with(&(&1["kind"] == "agent"))

    with {:ok, located} <- subscribers(scope, subscribers),
         {:ok, known} <- agents(scope, agents),
         do: {:ok, Map.merge(located, known)}
  end

  defp subscribers(scope, refs) do
    Enum.reduce_while(refs, {:ok, %{}}, fn ref, {:ok, acc} ->
      case Relay.Subscribers.locate(scope, ref["id"]) do
        {:ok, id} -> {:cont, {:ok, Map.put(acc, ref, id)}}
        {:error, _reason} -> {:halt, {:error, unavailable()}}
      end
    end)
  end

  defp agents(_scope, []), do: {:ok, %{}}

  defp agents(scope, refs) do
    decoded = Map.new(refs, &{&1, agent_id(&1["id"])})
    ids = decoded |> Map.values() |> Enum.reject(&is_nil/1)

    case Relay.Agents.known_recipients(scope, ids) do
      {:ok, known} ->
        agents = for {id, "agent"} <- known, into: MapSet.new(), do: id
        {:ok, Map.new(decoded, fn {ref, id} -> {ref, if(id in agents, do: id)} end)}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  defp agent_id(text) do
    case Relay.ExternalId.decode(text, ["agt"]) do
      {:ok, id} -> id
      {:error, _error} -> nil
    end
  end

  # AG-17
  @doc "The stored form of a resolved reference: its kind and the recipient identifier as text."
  @spec stored(ref(), Relay.Id.t()) :: stored()
  def stored(%{"kind" => kind}, id), do: %{"kind" => kind, "id" => Relay.Id.to_string(id)}

  # AG-17
  @doc "The names of resolved references by stored recipient identifier: what `view/2` needs to show the references of a request again."
  @spec names(%{ref() => Relay.Id.t() | nil}) :: names()
  def names(resolved) do
    for {%{"kind" => "subscriber", "id" => external_id}, id} <- resolved,
        id != nil,
        into: %{},
        do: {Relay.Id.to_string(id), external_id}
  end

  # AG-17
  @doc "The external identifiers of the stored subscriber references among `stored`, by stored recipient identifier; a deleted or erased subscriber has none."
  @spec read_names(Relay.Scope.t(), [stored()]) :: {:ok, names()} | {:error, Relay.Error.t()}
  def read_names(%Relay.Scope{} = scope, stored) when is_list(stored) do
    ids =
      for %{"kind" => "subscriber", "id" => text} <- stored,
          {:ok, id} <- [Relay.Id.parse(text)],
          uniq: true,
          do: id

    case named(scope, ids) do
      {:ok, names} -> {:ok, Map.new(names, &text_key/1)}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp text_key({id, name}), do: {Relay.Id.to_string(id), name}

  defp named(_scope, []), do: {:ok, %{}}
  defp named(scope, ids), do: Relay.Subscribers.external_ids(scope, ids)

  # AG-17
  @doc "The API form of a stored reference, or `nil` for a subscriber that has no name any more."
  @spec view(stored(), names()) :: ref() | nil
  def view(%{"kind" => "agent", "id" => text}, _names) do
    case Relay.Id.parse(text) do
      {:ok, id} -> %{"kind" => "agent", "id" => Views.id("agt", id)}
      {:error, _error} -> nil
    end
  end

  def view(%{"kind" => "subscriber", "id" => text}, names) do
    case Map.get(names, text) do
      nil -> nil
      external_id -> %{"kind" => "subscriber", "id" => external_id}
    end
  end

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
