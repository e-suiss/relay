defmodule Relay.Api.Throttles do
  @moduledoc """
  Throttle keys in the server API (WF-32, API-69): `POST /v1/throttles/{key}/reset` resets the active counter of a tenant-wide key inside the request's transaction, audited as `throttle.reset`, so every workflow that throttles on the key counts again from zero in the current window. A key without an active window, a key that cannot exist and a key of another tenant or environment are all `404 throttle_not_found`.
  """

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # WF-32
  # API-69
  @doc "Resets the active counter of a key inside the request's scoped transaction."
  @spec reset(Relay.Scope.t(), String.t(), Relay.Actor.t()) :: answer()
  def reset(scope, key, actor) do
    case Relay.Workflow.reset_throttle(scope, key, actor) do
      {:ok, {:reset, _counter_id}} ->
        {:ok, {200, [], %{"object" => "throttle_reset", "key" => key}}}

      _not_active_or_invalid ->
        {:error, Relay.Error.new(:throttle_not_found, "no active throttle has this key")}
    end
  end
end
