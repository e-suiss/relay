defmodule Relay.Access.Discovery do
  @moduledoc """
  The Access discovery documents (E-78, E-92), all under the configured issuer: the OpenID Provider Configuration (`/.well-known/openid-configuration`, OIDC Discovery and RFC 8414), which names the key set (`jwks_uri`) and the token endpoint; the Suiss configuration (`/.well-known/suiss-configuration`, Access OP-149 item 3), which names the Suiss members `suiss_region`, `suiss_relay`, `suiss_management_api` and `suiss_event_subscriptions` (an object whose `ssf_configuration` is the address of the event transmitter metadata), and whose `endpoints` name the address template of the tenant snapshot (`tenant_snapshot`) and the platform routes of the pairing (E-101): `pairing_challenges` and `pairing`, templates that hold `{tenant}`, and `platform_streams`, an address; and the AuthZEN configuration (`/.well-known/authzen-configuration`). The `issuer` of the OpenID and Suiss documents must equal the configured issuer byte for byte, and every URL they name must use HTTPS.
  """

  @type document :: %{
          issuer: String.t(),
          jwks_uri: String.t(),
          token_endpoint: String.t() | nil
        }

  @type suiss :: %{
          region: String.t() | nil,
          relay: String.t() | nil,
          management_api: String.t() | nil,
          event_subscriptions: String.t() | nil,
          tenant_snapshot: String.t() | nil,
          pairing_challenges: String.t() | nil,
          pairing: String.t() | nil,
          platform_streams: String.t() | nil
        }

  # E-78
  @doc "The address of the OpenID Provider Configuration of an issuer."
  @spec openid_url(String.t()) :: String.t()
  def openid_url(issuer), do: base(issuer) <> "/.well-known/openid-configuration"

  # E-92
  @doc "The address of the Suiss configuration of an issuer."
  @spec suiss_url(String.t()) :: String.t()
  def suiss_url(issuer), do: base(issuer) <> "/.well-known/suiss-configuration"

  # E-78
  @doc "The address of the AuthZEN configuration of an issuer."
  @spec authzen_url(String.t()) :: String.t()
  def authzen_url(issuer), do: base(issuer) <> "/.well-known/authzen-configuration"

  defp base(issuer), do: String.trim_trailing(issuer, "/")

  # E-78
  @doc "Reads the members of a provider configuration that the link uses."
  @spec parse(map(), String.t()) :: {:ok, document()} | {:error, Relay.Error.t()}
  def parse(%{"issuer" => issuer, "jwks_uri" => jwks_uri} = document, issuer) do
    if https?(jwks_uri) and optional_https?(document["token_endpoint"]) do
      {:ok, %{issuer: issuer, jwks_uri: jwks_uri, token_endpoint: document["token_endpoint"]}}
    else
      invalid("the discovery document names an address that is not HTTPS")
    end
  end

  def parse(%{"issuer" => _other}, _issuer),
    do: invalid("the discovery document names another issuer")

  def parse(_document, _issuer), do: invalid("the discovery document lacks issuer or jwks_uri")

  # E-92
  # E-96
  # E-101
  # INV-41
  @doc "Reads the Suiss members of a Suiss configuration, the address template of the tenant snapshot (`endpoints.tenant_snapshot`, Access OP-149 item 4) and those of the pairing routes (`endpoints.pairing_challenges` and `endpoints.pairing`), which must hold `{tenant}`, and the address of the platform streams (`endpoints.platform_streams`), which must hold no template."
  @spec parse_suiss(map(), String.t()) :: {:ok, suiss()} | {:error, Relay.Error.t()}
  def parse_suiss(%{"issuer" => issuer} = document, issuer) do
    events = event_subscriptions(document["suiss_event_subscriptions"])
    endpoints = endpoints(document["endpoints"])
    urls = [document["suiss_relay"], document["suiss_management_api"], events]

    if Enum.all?(urls ++ Map.values(endpoints), &optional_https?/1) do
      {:ok,
       Map.merge(endpoints, %{
         region: text(document["suiss_region"]),
         relay: document["suiss_relay"],
         management_api: document["suiss_management_api"],
         event_subscriptions: events
       })}
    else
      invalid("the Suiss configuration names an address that is not HTTPS")
    end
  end

  def parse_suiss(%{"issuer" => _other}, _issuer),
    do: invalid("the Suiss configuration names another issuer")

  def parse_suiss(_document, _issuer), do: invalid("the Suiss configuration lacks issuer")

  defp endpoints(endpoints) do
    endpoints = if is_map(endpoints), do: endpoints, else: %{}

    %{
      tenant_snapshot: endpoint(endpoints, "tenant_snapshot", true),
      pairing_challenges: endpoint(endpoints, "pairing_challenges", true),
      pairing: endpoint(endpoints, "pairing", true),
      platform_streams: endpoint(endpoints, "platform_streams", false)
    }
  end

  defp endpoint(endpoints, name, templated?) do
    case endpoints[name] do
      nil -> nil
      url when is_binary(url) -> if template?(url, templated?), do: url, else: :invalid
      _other -> :invalid
    end
  end

  defp template?(url, true), do: String.contains?(url, "{tenant}")
  defp template?(url, false), do: not String.contains?(url, ["{", "}"])

  defp event_subscriptions(nil), do: nil
  defp event_subscriptions(%{"ssf_configuration" => url}) when is_binary(url), do: url
  defp event_subscriptions(_value), do: :invalid

  defp https?(url) when is_binary(url), do: String.starts_with?(url, "https://")
  defp https?(_url), do: false

  defp optional_https?(nil), do: true
  defp optional_https?(url), do: https?(url)

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  defp invalid(message), do: {:error, Relay.Error.new(:access_discovery_invalid, message)}
end
