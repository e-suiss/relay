defmodule RelayWeb.Api.Admission do
  @moduledoc """
  Admission control at the API entrance (T-35, T-92, API-51), called by the operations that accept work before any of it is recorded. It asks `Relay.Platform.admit/1` with the node's load shedding state and its sampled bulk lane capacities (`L_max = μ · W_max`, `Relay.Platform.lane_capacity/0`); overload is `503 service_unavailable` with `Retry-After`, never `429`, and a `security` message is never refused.
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
  # API-51
  @doc "Turns an admission decision for `input` (`t:Relay.Platform.Admission.input/0`) into the API answer."
  @spec decide(map()) :: :ok | {:error, Relay.Error.t()}
  def decide(input) do
    case Relay.Platform.admit(input) do
      :admit ->
        :ok

      {:reject, %{retry_after_s: retry, rule_id: rule}} ->
        message = "Relay is overloaded (#{rule})"
        {:error, Relay.Error.new(:service_unavailable, message, %{retry_after: retry})}
    end
  end
end
