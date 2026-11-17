defmodule Relay.Workflow.OtpChain do
  @moduledoc """
  The channel chain of an `otp_oob` notification (PC-53, WF-18, E-33): not a fixed order but a function of its inputs. It orders the OTP channels a route names; it never adds a channel, so the chain stays inside the sender's permitted channels (PC-52), and it never names e-mail (INV-23).

  The inputs:

    * `permitted`: the sender's permitted channels (the request's `channels`), or `:all` when the request narrows nothing.
    * `country`: the recipient's country when it is known, with `closed`: the channels the destination protections close for that country (SMS to a country that is not on the tenant's allow-list or is stopped, CH-54).
    * `whatsapp_reachable`: whether the recipient's WhatsApp reachability is known.
    * `unhealthy`: the channels no provider can take a send on right now.
    * `sim_changed` and `mobile_app_active`: the sender's own signals (E-32, E-33), `nil` when it sent none. Relay never produces them.

  The order starts from the order the route writes and applies, in turn: when the sender says the SIM changed and WhatsApp reachability is known, WhatsApp goes before the channels bound to the SIM (`sms`, `voice`); an unhealthy channel goes behind the healthy ones and a closed channel, which would be stopped, behind every channel that is open; and WhatsApp is never first unless its reachability is known, as long as another channel is in the chain. `mobile_app_active` moves nothing: none of the OTP channels is the application, so it is carried with the inputs and recorded with them.

  The inputs are gathered once, when the notification is created, and frozen with its run, so every evaluation of the route gives the same order.
  """

  @channels ~w(sms whatsapp voice)
  @sim_bound ~w(sms voice)

  @type channel :: String.t()
  @type inputs :: %{
          optional(:permitted) => [channel()] | :all,
          optional(:country) => String.t() | nil,
          optional(:closed) => [channel()],
          optional(:whatsapp_reachable) => boolean(),
          optional(:unhealthy) => [channel()],
          optional(:sim_changed) => boolean() | nil,
          optional(:mobile_app_active) => boolean() | nil
        }

  # PC-51
  # INV-23
  @doc "The channels an `otp_oob` notification may use."
  @spec channels() :: [channel(), ...]
  def channels, do: @channels

  # PC-53
  # PC-52
  # WF-18
  @doc "Orders the OTP channels among `written`, the channels a route names in the order it writes them, by the inputs. A channel that is not an OTP channel or not permitted is left out."
  @spec order([channel()], inputs()) :: [channel()]
  def order(written, inputs) when is_list(written) and is_map(inputs) do
    permitted = Map.get(inputs, :permitted, :all)
    known? = Map.get(inputs, :whatsapp_reachable, false) == true
    unhealthy = Map.get(inputs, :unhealthy, [])
    closed = Map.get(inputs, :closed, [])

    written
    |> Enum.uniq()
    |> Enum.filter(&(&1 in @channels and permitted?(permitted, &1)))
    |> sim(Map.get(inputs, :sim_changed) == true and known?)
    |> behind(&(&1 in unhealthy))
    |> behind(&(&1 in closed))
    |> whatsapp(known?)
  end

  defp permitted?(:all, _channel), do: true
  defp permitted?(permitted, channel) when is_list(permitted), do: channel in permitted

  defp behind(channels, last?) do
    {last, first} = Enum.split_with(channels, last?)
    first ++ last
  end

  # E-33
  defp sim(channels, true), do: behind(channels, &(&1 in @sim_bound))
  defp sim(channels, false), do: channels

  # PC-53
  defp whatsapp(["whatsapp", next | rest], false), do: [next, "whatsapp" | rest]
  defp whatsapp(channels, _known?), do: channels

  # PC-53
  @doc "The inputs of a chain from their frozen JSON form (string keys), as a run's plan keeps them; `nil` for a run that froze none."
  @spec thaw(map() | nil) :: inputs() | nil
  def thaw(%{} = frozen) do
    %{
      permitted: Map.get(frozen, "permitted") || :all,
      country: Map.get(frozen, "country"),
      closed: Map.get(frozen, "closed") || [],
      whatsapp_reachable: Map.get(frozen, "whatsapp_reachable") == true,
      unhealthy: Map.get(frozen, "unhealthy") || [],
      sim_changed: Map.get(frozen, "sim_changed"),
      mobile_app_active: Map.get(frozen, "mobile_app_active")
    }
  end

  def thaw(nil), do: nil
end
