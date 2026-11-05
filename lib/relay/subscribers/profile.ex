defmodule Relay.Subscribers.Profile do
  @moduledoc """
  Pure rules of a subscriber profile: normalisation of contact fields before they are indexed and encrypted (email lowercase, phone in E.164), masking for API answers (X-5: personal fields are never returned in full) and the reachability summary of each channel (S-85, CH-28), derived when read and never stored.
  """

  @fields ~w(email phone name locale timezone legal_type attributes)
  @phone_channels ~w(sms voice whatsapp)

  @doc "The profile fields a subscriber write may carry."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  # C-19
  # API-21
  @doc "Normalises an email address: trimmed and lowercase."
  @spec email(String.t()) :: String.t()
  def email(value) when is_binary(value), do: value |> String.trim() |> String.downcase()

  # X-5
  @doc "Masks an email address: its first character, three stars and the domain."
  @spec mask_email(String.t() | nil) :: String.t() | nil
  def mask_email(nil), do: nil

  def mask_email(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] -> String.slice(local, 0, 1) <> "***@" <> domain
      _ -> "***"
    end
  end

  # X-5
  @doc "Masks a display name: its first character and three stars."
  @spec mask_name(String.t() | nil) :: String.t() | nil
  def mask_name(nil), do: nil
  def mask_name(name), do: String.slice(name, 0, 1) <> "***"

  # API-66
  # CH-28
  @doc "The reachability summary per channel from the states of the subscriber's email and phone addresses and the summaries of its push and Web Push devices (`permitted`, `no_permission`, or `nil` without a device that is not disabled)."
  @spec channels(String.t() | nil, String.t() | nil, String.t() | nil, String.t() | nil) ::
          %{String.t() => map()}
  def channels(email_state, phone_state, push \\ nil, web_push \\ nil) do
    phone = reach(phone_state)

    %{"email" => reach(email_state), "in_app" => %{"reachable" => true, "reason" => nil}}
    |> Map.merge(Map.new(@phone_channels, &{&1, phone}))
    |> Map.merge(%{"push" => device(push), "web_push" => device(web_push)})
  end

  defp device("permitted"), do: %{"reachable" => true, "reason" => nil}
  defp device("no_permission"), do: %{"reachable" => false, "reason" => "no_permission"}
  defp device(_none), do: %{"reachable" => false, "reason" => "no_active_device"}

  defp reach("active"), do: %{"reachable" => true, "reason" => nil}
  defp reach("disabled"), do: %{"reachable" => false, "reason" => "address_disabled"}
  defp reach(_none), do: %{"reachable" => false, "reason" => "no_address"}
end
