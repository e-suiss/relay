defmodule Relay.Policy.Defaults do
  @moduledoc """
  The default of a category × channel cell when the recipient's value is `unset` (PC-13, PC-14): the tenant's category default, otherwise the class default matrix. The matrix has the columns push, email, SMS, WhatsApp and in-app; web push reads the push column, voice the SMS column, Slack, Teams, Telegram and Discord the WhatsApp column and webhook the in-app column.

  A cell can be locked off by the compliance table (PC-14 ¹ ², PC-54): on a channel whose platform row keeps `marketing` off (iOS push, WhatsApp) and on a channel whose country row asks for prior consent, the default is always off and a tenant default of `on` does not apply; only the recipient's own `opt_in` opens the cell. `system` has no preference surface and is always on.
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
  @doc "The default of a cell and where it came from: the tenant's category default when it applies, otherwise the class default. `cell` is the cell's derived state from the compliance table: `:locked_off` or `:tenant`."
  @spec default(
          Snapshot.message_class(),
          Snapshot.channel(),
          %{optional(Snapshot.channel()) => :on | :off},
          :locked_off | :tenant
        ) :: {:on | :off, source()}
  def default(class, channel, channel_defaults, cell) do
    case {Map.get(channel_defaults, channel), cell} do
      {:off, _cell} -> {:off, :category_default}
      {_on_or_none, :locked_off} -> {:off, :class_default}
      {:on, :tenant} -> {:on, :category_default}
      {nil, :tenant} -> {class_default(class, channel), :class_default}
    end
  end
end
