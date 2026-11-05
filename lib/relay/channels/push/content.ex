defmodule Relay.Channels.Push.Content do
  @moduledoc """
  What a push payload may carry (INV-60, CH-33, CH-67). No push payload carries a one-time code, a secret or an authentication link: push is not an out-of-band OTP channel. `check/1` walks every key and string of a built payload and refuses one that looks like any of them; a value of a secret type (`Relay.Redacted`) is refused outright. The check fails closed: a refused payload is a content failure, never sent in a weaker form.

  A content-free push carries only "there is a new notification" and an opaque identifier; the application fetches the content from Relay over TLS (CH-33). It is the default for tenants in the Türkiye region and with the domestic-only policy, and in every region for the `security` class; a `sensitive` notification is always content-free and shows only neutral text on the lock screen, whatever its interruption level (CH-67). The payload stays visible to the platform as metadata: it carries no content, which is not a claim of zero knowledge.
  """

  alias Relay.Error

  @otp_words "otp|one[- ]time|passcode|pass code|verification|security code|login code|code|kod|kodu|kodunuz|şifre|şifreniz|parola|doğrulama|pin"
  @otp_before ~r/(?<!\w)(?:#{@otp_words})(?!\w)\W{0,3}(?:\w+\W{1,3}){0,3}\d{4,8}(?!\d)/iu
  @otp_after ~r/(?<!\d)\d{4,8}\W{1,3}(?:is your|is the|kodunuz|kodudur|şifreniz|code)/iu
  @url ~r/[a-z][a-z0-9+.-]*:\/\/[^\s"'<>]+/iu
  @jwt ~r/eyJ[A-Za-z0-9_-]{6,}\.eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]*/
  @secret ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----|\bAKIA[0-9A-Z]{16}\b|\bsk_live_[0-9A-Za-z]{8,}|\bxox[abpr]-[0-9A-Za-z-]{8,}|\bghp_[0-9A-Za-z]{30,}/
  @link_params ~w(token access_token id_token refresh_token auth auth_token code otp magic magic_link login_token signin sig signature key secret password pass session session_id nonce ticket reset reset_token verify verification verification_token confirmation_token jwt)
  @link_paths ~r/magic[-_]?link|\/auth\/callback|\/verify[-_]?email|\/reset[-_]?password|\/one[-_]?time/i
  @keys ~w(otp otp_code one_time_code password passcode secret access_token refresh_token id_token auth_token magic_link login_link)

  @neutral %{
    "tr" => %{"title" => "Yeni bildirim", "body" => "Yeni bir bildiriminiz var."},
    "en" => %{"title" => "New notification", "body" => "You have a new notification."}
  }

  @type kind :: :otp_code | :auth_link | :secret

  # INV-60
  # CH-33
  @doc "Checks that a payload carries no one-time code, secret or authentication link; the error names the path and the kind, never the value."
  @spec check(term()) :: :ok | {:error, Error.t()}
  def check(payload) do
    case find(payload, []) do
      nil -> :ok
      {kind, path} -> {:error, forbidden(kind, path)}
    end
  end

  defp forbidden(kind, path) do
    Error.new(:push_content_forbidden, "a push payload carries no code, secret or link", %{
      kind: kind,
      path: path |> Enum.reverse() |> Enum.join(".")
    })
  end

  defp find(%Relay.Redacted{}, path), do: {:secret, path}

  defp find(%{} = map, path) when not is_struct(map) do
    Enum.find_value(map, fn {key, value} ->
      key = to_string(key)

      if String.downcase(key) in @keys do
        {:secret, [key | path]}
      else
        find(value, [key | path])
      end
    end)
  end

  defp find(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.find_value(fn {value, index} -> find(value, [Integer.to_string(index) | path]) end)
  end

  defp find(text, path) when is_binary(text) do
    case kind(text) do
      nil -> nil
      kind -> {kind, path}
    end
  end

  defp find(_value, _path), do: nil

  # INV-60
  @doc "The kind of forbidden content a text carries, `nil` when it carries none."
  @spec kind(String.t()) :: kind() | nil
  def kind(text) when is_binary(text) do
    cond do
      Regex.match?(@secret, text) or Regex.match?(@jwt, text) -> :secret
      auth_link?(text) -> :auth_link
      Regex.match?(@otp_before, text) or Regex.match?(@otp_after, text) -> :otp_code
      true -> nil
    end
  end

  defp auth_link?(text) do
    @url
    |> Regex.scan(text)
    |> Enum.any?(fn [url] -> link?(url) end)
  end

  defp link?(url) do
    %URI{path: path, query: query, fragment: fragment} = URI.parse(url)
    Regex.match?(@link_paths, path || "") or params?(query) or params?(fragment)
  end

  defp params?(nil), do: false

  defp params?(text) do
    text
    |> String.split(["&", ";"], trim: true)
    |> Enum.any?(fn pair ->
      name = pair |> String.split("=", parts: 2) |> hd() |> String.downcase()
      name in @link_params
    end)
  end

  # CH-33
  @doc """
  Whether a notification goes content-free. `sensitive` (the message flag or the template's sensitivity class) always does. Otherwise the tenant's or category's explicit `choice` decides, and without one the default holds: on in the Türkiye region and under the domestic-only policy, and for the `security` class in every region.
  """
  @spec content_free?(map()) :: boolean()
  def content_free?(input) when is_map(input) do
    cond do
      Map.get(input, :sensitive, false) == true -> true
      is_boolean(Map.get(input, :choice)) -> Map.fetch!(input, :choice)
      true -> default_content_free?(input)
    end
  end

  defp default_content_free?(input) do
    domestic = Map.get(input, :domestic_only, false) == true
    security = Map.get(input, :message_class) == :security
    Map.get(input, :region) == "tr" or domestic or security
  end

  # CH-67
  # TP-21
  @doc "The neutral lock screen alert: the template's `lock_screen_body` when given, otherwise a generic text in the locale's language (Turkish or English)."
  @spec neutral(String.t() | nil, String.t() | nil) :: %{String.t() => String.t()}
  def neutral(locale, lock_screen_body \\ nil) do
    text = Map.fetch!(@neutral, language(locale))

    case lock_screen_body do
      body when is_binary(body) and body != "" -> %{text | "body" => body}
      _none -> text
    end
  end

  defp language(locale) when is_binary(locale) do
    case locale |> String.downcase() |> String.split(["-", "_"], parts: 2) do
      ["tr" | _] -> "tr"
      _other -> "en"
    end
  end

  defp language(_locale), do: "en"
end
