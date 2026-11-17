defmodule Relay.Channels.Commercial do
  @moduledoc """
  The commercial message declaration a provider is told about an SMS or a voice call (PC-4): whether the message is a commercial electronic message and, when it is, the İYS recipient type the provider's İYS filter checks it against. The declaration is the service provider's own statement, so it is always derived, never left to a provider default: `commercial` from the message class (only `marketing` is commercial), the recipient type from the `recipient_type` of the recipient's consent copy (`individual` is `BIREYSEL`, `merchant` is `TACIR`). A commercial message whose consent copy names no type is declared `BIREYSEL`, the stricter filter. The channel step records the declaration on the attempt (`Relay.Delivery.declare_attempt/4`), so what was declared for a send can be read back.
  """

  alias Relay.Channels.Request

  @type t :: %{commercial: boolean(), iys_recipient_type: String.t() | nil}

  # PC-4
  @doc "The declaration of a message of `message_class` to a recipient whose consent copy has `recipient_type` (`individual`, `merchant` or `nil`)."
  @spec declaration(String.t() | nil, String.t() | nil) :: t()
  def declaration("marketing", recipient_type),
    do: %{commercial: true, iys_recipient_type: iys(recipient_type)}

  def declaration(_message_class, _recipient_type),
    do: %{commercial: false, iys_recipient_type: nil}

  defp iys("merchant"), do: "TACIR"
  defp iys(_individual_or_unknown), do: "BIREYSEL"

  # PC-4
  @doc "The declaration of a provider call: the one the channel step decided, otherwise the one its message class gives."
  @spec of(Request.t()) :: t()
  def of(%Request{commercial: %{commercial: _, iys_recipient_type: _} = declared}), do: declared

  def of(%Request{message_class: message_class}), do: declaration(message_class, nil)

  # PC-4
  @doc "The consent copy's `recipient_type` for a delivery on `channel` of the brand `brand` (its sub-tenant, `nil` for the tenant itself) among a recipient's current consents; `nil` when the brand has no active consent on the channel."
  @spec recipient_type([map()], String.t(), Relay.Id.t() | nil) :: String.t() | nil
  def recipient_type(consents, channel, brand) when is_list(consents) do
    Enum.find_value(consents, fn consent ->
      own? = consent["channel"] == channel and consent["brand_subtenant_id"] == brand
      if own? and consent["status"] == "active", do: consent["recipient_type"]
    end)
  end
end
