defmodule Relay.Policy.Defaults do
  @moduledoc """
  The default of a category × channel cell when the recipient's value is `unset` (PC-13, PC-14): the tenant's category default, otherwise the class default matrix. The matrix has the columns push, email, SMS, WhatsApp and in-app; web push reads the push column, voice the SMS column, Slack, Teams, Telegram and Discord the WhatsApp column and webhook the in-app column.

  `marketing` starts safe-closed: on email, SMS, voice and WhatsApp, and on push to a device that is not Android, a tenant default of `on` does not apply, because the country and platform rows ask for prior consent (PC-14 ¹ ², PC-54, PC-58 (3)). `system` has no preference surface and is always on.
  """

  alias Relay.Policy.Snapshot

  @matrix %{
    security: %{push: :on, email: :on, sms: :on, whatsapp: :off, in_app: :on},
    action_required: %{push: :on, email: :on, sms: :off, whatsapp: :off, in_app: :on},
    transactional: %{push: :on, email: :on, sms: :on, whatsapp: :off, in_app: :on},
    operational: %{push: :on, email: :on, sms: :off, whatsapp: :off, in_app: :on},
    social: %{push: :on, email: :off, sms: :off, whatsapp: :off, in_app: :on},
    marketing: %{push: :off, email: :off, sms: :off, whatsapp: :off, in_app: :on}
  }

  @columns %{
    push: :push,
    web_push: :push,
    email: :email,
    sms: :sms,
    voice: :sms,
    whatsapp: :whatsapp,
    slack: :whatsapp,
    teams: :whatsapp,
    telegram: :whatsapp,
    discord: :whatsapp,
    in_app: :in_app,
    webhook: :in_app
  }

  @consent_channels [:email, :sms, :voice, :whatsapp]

  @type source :: :category_default | :class_default

  # PC-14
  @doc "The class default of a channel."
  @spec class_default(Snapshot.message_class(), Snapshot.channel()) :: :on | :off
  def class_default(:system, _channel), do: :on

  def class_default(class, channel),
    do: @matrix |> Map.fetch!(class) |> Map.fetch!(Map.fetch!(@columns, channel))

  # PC-13
  # PC-14
  # PC-54
  # PC-58 (3)
  @doc "The default of a cell and where it came from: the tenant's category default when it applies, otherwise the class default."
  @spec default(
          Snapshot.message_class(),
          Snapshot.channel(),
          %{optional(Snapshot.channel()) => :on | :off},
          :ios | :android | :web | nil
        ) :: {:on | :off, source()}
  def default(class, channel, channel_defaults, platform) do
    case Map.get(channel_defaults, channel) do
      value when value in [:on, :off] ->
        if forced_off?(class, channel, platform, value),
          do: {:off, :class_default},
          else: {value, :category_default}

      nil ->
        {class_default(class, channel), :class_default}
    end
  end

  defp forced_off?(:marketing, channel, _platform, :on) when channel in @consent_channels,
    do: true

  defp forced_off?(:marketing, :push, platform, :on), do: platform != :android
  defp forced_off?(_class, _channel, _platform, _value), do: false
end
