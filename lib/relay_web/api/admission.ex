defmodule RelayWeb.Api.Admission do
  @moduledoc """
  Admission control at the API entrance (T-35, T-92, API-51), called by the operations that accept work before any of it is recorded. It asks `Relay.Platform.admit/1` with the node's load shedding state and its sampled bulk lane capacities (`L_max = μ · W_max`, `Relay.Platform.lane_capacity/0`); overload is `503 service_unavailable` with `Retry-After`, input above the lane's AIMD ceiling is `429 rate_limited` with `Retry-After` (T-97), and a `security` message is never refused.
  """

  @lanes [:l1, :l2, :l3]

  # T-35
  # T-35 (2)
  # API-51
  @doc "Admits a request of a message class for the channels it asks for, from this node's load shedding state and lane capacities."
  @spec check(atom(), [atom()]) :: :ok | {:error, Relay.Error.t()}
  def check(message_class, channels) do
    shed = Map.new(@lanes, &{&1, Relay.Platform.load_shed_engaged?(&1)})

    decide(%{
      message_class: message_class,
      channels: channels,
      shed: shed,
      breaker_open: MapSet.new(),
      lane_capacity: Relay.Platform.lane_capacity()
    })
  end

  # T-35
  # T-92
  # T-97
  # API-51
  @doc "Turns an admission decision for `input` (`t:Relay.Platform.Admission.input/0`) into the API answer."
  @spec decide(map()) :: :ok | {:error, Relay.Error.t()}
  def decide(input) do
    case Relay.Platform.admit(input) do
      :admit ->
        :ok

      {:reject, rejection} ->
        {:error, error(rejection)}
    end
  end

  # T-35
  # T-97
  @doc "The API error of an admission rejection: `429 rate_limited` above an input ceiling, `503 service_unavailable` otherwise."
  @spec error(Relay.Platform.Admission.rejection()) :: Relay.Error.t()
  def error(%{status: 429, retry_after_s: retry, rule_id: rule}) do
    message = "the lane's input is above its ceiling (#{rule})"
    Relay.Error.new(:rate_limited, message, %{retry_after: retry, limit_name: rule})
  end

  def error(%{retry_after_s: retry, rule_id: rule}) do
    message = "Relay is overloaded (#{rule})"
    Relay.Error.new(:service_unavailable, message, %{retry_after: retry})
  end
end
