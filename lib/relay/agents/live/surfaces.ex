defmodule Relay.Agents.Live.Surfaces do
  @moduledoc """
  The surfaces an invitation reaches, pure (AG-28, AG-63). A responder is reachable on e-mail and SMS when it has an active address, and on every device that is not disabled and has given its permission. An invitation without named surfaces takes all of them at the same time; one that names surfaces takes those of them the responder has, a channel standing for every device of it; one that names exceptions takes the rest. The inbox record is added when the invitation carries it and is never ordered by a policy.

  A surface the responder does not have is left out; an invitation that reaches no interrupting surface is the caller's to report.
  """

  @type target :: %{
          channel: :email | :sms | :push | :web_push | :in_app,
          device_id: Relay.Id.t() | nil,
          provider: String.t() | nil
        }

  @permitted ["granted", "provisional"]

  # AG-28
  # AG-63
  @doc "The targets of an invitation's `surfaces` and `inbox` for the subscriber row `recipient` (its `email_state` and `phone_state`) and its `devices`."
  @spec select(term(), boolean(), map(), [map()]) :: [target()]
  def select(surfaces, inbox, recipient, devices) do
    reachable = reachable(recipient, devices)
    inbox = if inbox, do: [%{channel: :in_app, device_id: nil, provider: nil}], else: []
    narrowed(surfaces, reachable) ++ inbox
  end

  # AG-63
  @doc "Whether a target interrupts: every surface but the inbox record."
  @spec interrupting?(target()) :: boolean()
  def interrupting?(%{channel: channel}), do: channel != :in_app

  defp reachable(recipient, devices) do
    addresses =
      for {channel, state} <- [email: recipient["email_state"], sms: recipient["phone_state"]],
          state == "active",
          do: %{channel: channel, device_id: nil, provider: nil}

    addresses ++ for(%{"permission" => p} = d <- devices, p in @permitted, do: device(d))
  end

  defp device(%{"id" => id, "platform" => platform}) do
    channel = if platform == "web_push", do: :web_push, else: :push
    %{channel: channel, device_id: id, provider: platform}
  end

  defp narrowed(nil, reachable), do: reachable

  defp narrowed(%{"except" => named}, reachable) when is_list(named),
    do: Enum.reject(reachable, &named?(&1, named))

  defp narrowed(named, reachable) when is_list(named),
    do: Enum.filter(reachable, &named?(&1, named))

  defp narrowed(_unknown, _reachable), do: []

  defp named?(target, named), do: Enum.any?(named, &names?(&1, target))

  defp names?(%{"channel" => channel}, target), do: channel == Atom.to_string(target.channel)

  defp names?(%{"device_id" => text}, %{device_id: <<_::128>> = id}),
    do: String.downcase(text) == Relay.Id.to_string(id)

  defp names?(_surface, _target), do: false
end
