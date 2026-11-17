defmodule Relay.Api.OtpChain do
  @moduledoc """
  The inputs of the OTP channel chain on the send path (PC-53, PC-52, E-33). The chain of an `otp_oob` notification is a function of its inputs (`Relay.Workflow.otp_order/2`); this module gathers them when the notification is created and freezes them in its run's plan, so a later evaluation of the route gives the same order:

    * the sender's permitted channels: the OTP channels of the request's steps, which its `channels` already narrowed (the chain never leaves them);
    * the recipient's country, when the request carries the recipient's phone number, and whether the destination protections close SMS for it (`Relay.DestinationGuard.open?/2`): a country that is not on the tenant's allow-list or is stopped;
    * whether the recipient's WhatsApp reachability is known: a WhatsApp delivery among its newest notifications reached `delivered` (`Relay.Delivery.channel_reached?/2`);
    * provider health: the channels no provider can take a send on right now (`Relay.Channels.unhealthy_channels/4`); on the test plane the fake provider answers and every channel is healthy;
    * the sender's own signals, `security_signals` of the request, when it sent them.

  A notification that is not `otp_oob` has no inputs and its routes run in the written order. The frozen inputs hold channel names, a country code and booleans, never a phone number.
  """

  alias Relay.Scope

  @otp ~w(sms whatsapp voice)
  @domestic "channels.domestic_only"
  @unknown %{country: nil, closed: []}

  @type prepared :: %{permitted: [String.t()], unhealthy: [String.t()], signals: map()}
  @type destination :: %{country: String.t() | nil, closed: [String.t()]}

  # PC-53
  # PC-52
  @doc "Gathers, outside any transaction, the inputs that do not depend on the recipient: the permitted OTP channels of the request's steps, the unhealthy ones among them under the tenant's `settings` and the sender's signals. `nil` for a request that is not `otp_oob`."
  @spec prepare(Scope.t(), map(), map()) :: prepared() | nil
  def prepare(%Scope{} = scope, %{security_subtype: "otp_oob"} = request, settings) do
    permitted = for %{channel: channel} <- request.steps, channel in @otp, uniq: true, do: channel

    %{
      permitted: permitted,
      unhealthy: unhealthy(scope, permitted, settings),
      signals: Map.get(request, :signals) || %{}
    }
  end

  def prepare(_scope, _request, _settings), do: nil

  # X-25
  defp unhealthy(%Scope{environment: :test}, _channels, _settings), do: []

  defp unhealthy(scope, channels, settings) do
    case Relay.Datasets.channel_declarations() do
      {:ok, declarations} ->
        policy = %{domestic_country: settings[@domestic]}
        Relay.Channels.unhealthy_channels(scope, channels, declarations, policy)

      {:error, _error} ->
        []
    end
  end

  # PC-53
  # CH-54
  @doc "Adds to each prepared recipient of an `otp_oob` request, outside any transaction, its destination: the country of the phone number the request carries for it and the channels closed for that country. Without inputs the recipients are returned unchanged."
  @spec destinations(Scope.t(), prepared() | nil, [map()]) :: [map()]
  def destinations(_scope, nil, recipients), do: recipients

  def destinations(%Scope{} = scope, %{}, recipients) do
    Enum.map(recipients, &Map.put(&1, :otp_destination, destination(scope, &1.fields)))
  end

  defp destination(scope, %{"phone" => phone}) when is_binary(phone) do
    if Relay.DestinationGuard.number?(phone) do
      country = Relay.DestinationGuard.country(phone)
      closed = if Relay.DestinationGuard.open?(scope, country), do: [], else: ["sms"]
      %{country: country, closed: closed}
    else
      @unknown
    end
  end

  defp destination(_scope, _fields), do: @unknown

  # PC-53
  @doc "The frozen inputs of a recipient's chain, as the run's plan keeps them, inside the accepting transaction; `nil` without inputs."
  @spec freeze(prepared() | nil, destination() | nil, Relay.Id.t()) :: map() | nil
  def freeze(nil, _destination, _recipient_id), do: nil

  def freeze(%{} = prepared, destination, recipient_id) do
    destination = destination || @unknown

    %{
      "permitted" => prepared.permitted,
      "country" => destination.country,
      "closed" => destination.closed,
      "whatsapp_reachable" => Relay.Delivery.channel_reached?(recipient_id, "whatsapp"),
      "unhealthy" => prepared.unhealthy,
      "sim_changed" => prepared.signals["sim_changed"],
      "mobile_app_active" => prepared.signals["mobile_app_active"]
    }
  end

  # PC-53
  @doc "The route facts of a run's steps from the frozen inputs of its plan: the inputs of the OTP chain, or nothing for a run that froze none."
  @spec facts(map() | nil) :: (map() -> map())
  def facts(nil), do: fn _step -> %{} end

  def facts(%{} = frozen) do
    inputs = Relay.Workflow.otp_inputs(frozen)
    fn _step -> %{otp: inputs} end
  end
end
