defmodule Relay.Devices.Token do
  @moduledoc """
  Pure rules of a device registration (C-23, CH-28, API-67): the registration is checked and normalised before its token is indexed and encrypted, the stored token value is built, and the permission rule decides which devices a message class may reach.

  * An APNs token is hex and stored lowercase; an FCM or HMS token is a printable string; a Web Push or UnifiedPush token is the `https` endpoint of the subscription and travels with its `keys`. A token of the simulated provider (`sim:<result>`, CH-72) is accepted for every platform.
  * `apns_environment` is required for `apns` and refused for the other platforms; `keys` is required for `web_push` and `unified_push` and refused for the others.
  * A device may receive a message when its permission is `granted`, or `provisional` for a `marketing` or `social` message (CH-28, CH-29).
  """

  @platforms ~w(apns fcm hms web_push unified_push)
  @web ~w(web_push unified_push)
  @apns ~r/\A[0-9a-f]{32,400}\z/
  @opaque_token ~r/\A[\x21-\x7E]{1,4096}\z/
  @simulated ~r/\Asim:[a-z_]{1,64}\z/
  @provisional_classes ~w(marketing social)

  @type registration :: %{
          platform: String.t(),
          token: String.t(),
          keys: %{String.t() => String.t()} | nil,
          app: String.t(),
          apns_environment: String.t() | nil,
          permission: String.t(),
          android_channels: [map()],
          locale: String.t() | nil,
          previous_token: String.t() | nil
        }

  @doc "The push platforms."
  @spec platforms() :: [String.t(), ...]
  def platforms, do: @platforms

  # C-23
  @doc "The channel a platform's devices serve: `web_push` for Web Push subscriptions, `push` for the others."
  @spec channel(String.t()) :: :push | :web_push
  def channel("web_push"), do: :web_push
  def channel(platform) when platform in @platforms, do: :push

  @doc "The platforms whose devices serve a channel."
  @spec platforms(:push | :web_push | String.t()) :: [String.t()]
  def platforms(channel) when channel in [:web_push, "web_push"], do: ["web_push"]
  def platforms(channel) when channel in [:push, "push"], do: @platforms -- ["web_push"]
  def platforms(_channel), do: []

  # CH-28
  # CH-29
  @doc "Whether a device with this permission may receive a message of this class; without a class only `granted` counts."
  @spec permitted?(String.t(), atom() | String.t() | nil) :: boolean()
  def permitted?("granted", _class), do: true

  def permitted?("provisional", class) when not is_nil(class),
    do: to_string(class) in @provisional_classes

  def permitted?(_permission, _class), do: false

  # API-67
  # CH-31
  @doc "Checks and normalises a registration body (already valid against the contract schema); a broken rule is `422 validation_failed` with its field errors."
  @spec registration(map()) :: {:ok, registration()} | {:error, Relay.Error.t()}
  def registration(%{"platform" => platform, "token" => token} = body) do
    keys = body["keys"]

    checks = [
      token_error(platform, token, "/token"),
      previous_error(platform, body["previous_token"]),
      keys_error(platform, keys),
      apns_error(platform, body["apns_environment"])
    ]

    case Enum.reject(checks, &is_nil/1) do
      [] ->
        {:ok,
         %{
           platform: platform,
           token: normalize(platform, token),
           keys: keys,
           app: body["app"],
           apns_environment: body["apns_environment"],
           permission: body["permission"],
           android_channels: body["android_channels"] || [],
           locale: body["locale"],
           previous_token: previous(platform, body["previous_token"])
         }}

      errors ->
        failed(errors)
    end
  end

  defp failed(errors) do
    {:error,
     Relay.Error.new(:validation_failed, "the registration breaks a rule", %{errors: errors})}
  end

  # API-67
  @doc "Normalises a token the caller names to find a device: trimmed, and lowercase when it is an APNs token."
  @spec lookup(String.t()) :: String.t()
  def lookup(token) when is_binary(token) do
    trimmed = String.trim(token)
    if Regex.match?(@apns, String.downcase(trimmed)), do: String.downcase(trimmed), else: trimmed
  end

  # TN-33
  @doc "The value stored encrypted for a registration: the token, or for a Web Push subscription its endpoint and keys as canonical JSON."
  @spec stored(registration()) :: binary()
  def stored(%{platform: platform, token: token, keys: keys}) when platform in @web do
    Jason.encode!(%{"endpoint" => token, "p256dh" => keys["p256dh"], "auth" => keys["auth"]})
  end

  def stored(%{token: token}), do: token

  # TN-33
  @doc "Reads a decrypted stored value back as the token and, for a Web Push subscription, its keys."
  @spec unstored(String.t(), binary()) :: {String.t(), %{String.t() => String.t()} | nil}
  def unstored(platform, value) when platform in @web do
    case Jason.decode(value) do
      {:ok, %{"endpoint" => endpoint, "p256dh" => p256dh, "auth" => auth}} ->
        {endpoint, %{"p256dh" => p256dh, "auth" => auth}}

      _other ->
        {value, nil}
    end
  end

  def unstored(_platform, value), do: {value, nil}

  defp normalize(platform, token) do
    trimmed = String.trim(token)
    if platform == "apns", do: String.downcase(trimmed), else: trimmed
  end

  defp previous(_platform, nil), do: nil
  defp previous(platform, token), do: normalize(platform, token)

  defp previous_error(_platform, nil), do: nil
  defp previous_error(platform, token), do: token_error(platform, token, "/previous_token")

  defp token_error(platform, token, pointer) do
    value = normalize(platform, token)

    cond do
      Regex.match?(@simulated, value) -> nil
      valid?(platform, value) -> nil
      true -> field(pointer, "invalid_format", message(platform))
    end
  end

  defp valid?("apns", value), do: Regex.match?(@apns, value)

  defp valid?(platform, value) when platform in @web do
    case URI.parse(value) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        Regex.match?(@opaque_token, value)

      _other ->
        false
    end
  end

  defp valid?(_platform, value), do: Regex.match?(@opaque_token, value)

  defp message("apns"), do: "an APNs token is hexadecimal"
  defp message(platform) when platform in @web, do: "the token is the https push endpoint"
  defp message(_platform), do: "the token is printable text without spaces"

  defp keys_error(platform, nil) when platform in @web,
    do: field("/keys", "required", "a Web Push subscription needs its keys")

  defp keys_error(platform, keys) when platform not in @web and not is_nil(keys),
    do: field("/keys", "not_allowed", "keys belong to Web Push subscriptions")

  defp keys_error(_platform, _keys), do: nil

  defp apns_error("apns", nil),
    do: field("/apns_environment", "required", "an APNs token needs its environment")

  defp apns_error(platform, value) when platform != "apns" and not is_nil(value),
    do: field("/apns_environment", "not_allowed", "only an APNs token has an APNs environment")

  defp apns_error(_platform, _value), do: nil

  defp field(pointer, code, detail), do: %{pointer: pointer, code: code, detail: detail}
end
