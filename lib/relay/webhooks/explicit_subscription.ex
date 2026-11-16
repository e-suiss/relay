defmodule Relay.Webhooks.ExplicitSubscription do
  @moduledoc """
  The subscription of an endpoint to an event type that `*` does not cover (WH-67, WH-16). Such a type, a record appended to the tenant's audit log, reaches only an endpoint whose selection names it. The type is added to the selection of an endpoint of use `relay_events`, as a change of the endpoint with its audit record; an endpoint that already names it stays as it is.

  Every function runs inside the caller's scoped transaction.
  """

  alias Relay.Actor
  alias Relay.Webhooks.Store

  # WH-67
  # WH-48
  @doc "Adds `event_type` to the selection of an endpoint of use `relay_events`; returns the result of the change and the endpoint's version. An endpoint of use `destination` is `:not_relay_events`."
  @spec add(Relay.Id.t(), String.t(), binary(), Actor.t()) :: {atom(), pos_integer() | nil}
  def add(id, event_type, digest, %Actor{} = actor) when is_binary(event_type) do
    case Store.endpoint(id) do
      nil -> {:not_found, nil}
      %{"use_kind" => "relay_events"} = endpoint -> added(endpoint, event_type, digest, actor)
      _destination -> {:not_relay_events, nil}
    end
  end

  defp added(%{"id" => id, "event_types" => types, "version" => version}, type, digest, actor) do
    if type in types,
      do: {:unchanged, version},
      else: Store.endpoint_update(id, nil, %{"event_types" => types ++ [type]}, digest, actor)
  end
end
