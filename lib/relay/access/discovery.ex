defmodule Relay.Access.Discovery do
  @moduledoc """
  The Access discovery documents (E-78): the OpenID Provider Configuration (`/.well-known/openid-configuration`, OIDC Discovery and RFC 8414) and the AuthZEN configuration (`/.well-known/authzen-configuration`), both under the configured issuer. The provider configuration names the key set (`jwks_uri`), the token endpoint and the Suiss extension members `suiss_region`, `suiss_management_api` and `suiss_event_subscriptions`. Its `issuer` must equal the configured issuer byte for byte, and every URL it names must use HTTPS.
  """

  @type document :: %{
          issuer: String.t(),
          jwks_uri: String.t(),
          token_endpoint: String.t() | nil,
          region: String.t() | nil,
          management_api: String.t() | nil,
          event_subscriptions: String.t() | nil
        }

  # E-78
  @doc "The address of the OpenID Provider Configuration of an issuer."
  @spec openid_url(String.t()) :: String.t()
  def openid_url(issuer), do: base(issuer) <> "/.well-known/openid-configuration"

  # E-78
  @doc "The address of the AuthZEN configuration of an issuer."
  @spec authzen_url(String.t()) :: String.t()
  def authzen_url(issuer), do: base(issuer) <> "/.well-known/authzen-configuration"

  defp base(issuer), do: String.trim_trailing(issuer, "/")

  # E-78
  # INV-41
  @doc "Reads the members of a provider configuration that the link uses."
  @spec parse(map(), String.t()) :: {:ok, document()} | {:error, Relay.Error.t()}
  def parse(%{"issuer" => issuer, "jwks_uri" => jwks_uri} = document, issuer) do
    optional = ["token_endpoint", "suiss_management_api", "suiss_event_subscriptions"]

    if https?(jwks_uri) and Enum.all?(optional, &optional_https?(document[&1])) do
      {:ok,
       %{
         issuer: issuer,
         jwks_uri: jwks_uri,
         token_endpoint: document["token_endpoint"],
         region: text(document["suiss_region"]),
         management_api: document["suiss_management_api"],
         event_subscriptions: document["suiss_event_subscriptions"]
       }}
    else
      invalid("the discovery document names an address that is not HTTPS")
    end
  end

  def parse(%{"issuer" => _other}, _issuer),
    do: invalid("the discovery document names another issuer")

  def parse(_document, _issuer), do: invalid("the discovery document lacks issuer or jwks_uri")

  defp https?(url) when is_binary(url), do: String.starts_with?(url, "https://")
  defp https?(_url), do: false

  defp optional_https?(nil), do: true
  defp optional_https?(url), do: https?(url)

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  defp invalid(message), do: {:error, Relay.Error.new(:access_discovery_invalid, message)}
end
