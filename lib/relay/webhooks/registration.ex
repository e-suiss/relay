defmodule Relay.Webhooks.Registration do
  @moduledoc """
  The registration rules of an HTTPS address (WH-40 (1) to (3)), pure: the scheme is `https`, on the test plane as well; the port is one the installation allows, 443 by default; the address carries no user information and names a host. These rules answer at once when an endpoint is registered. They are not the security boundary: every address the host resolves to is checked when Relay connects (WH-41).
  """

  @type reason :: :invalid | :not_https | :user_information | :no_host | :port_not_allowed

  # WH-40
  @doc "Checks `url` against the registration rules with the allowed `ports`."
  @spec check(String.t(), [pos_integer(), ...]) :: :ok | {:error, reason()}
  def check(url, [_ | _] = ports) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https"} = uri} -> address(uri, ports)
      {:ok, %URI{}} -> {:error, :not_https}
      {:error, _part} -> {:error, :invalid}
    end
  end

  defp address(%URI{userinfo: userinfo}, _ports) when userinfo != nil,
    do: {:error, :user_information}

  defp address(%URI{host: host}, _ports) when host in [nil, ""], do: {:error, :no_host}

  defp address(%URI{port: port}, ports),
    do: if(port in ports, do: :ok, else: {:error, :port_not_allowed})

  # WH-40
  @doc "The sentence that explains a refusal to the caller."
  @spec explain(reason()) :: String.t()
  def explain(:invalid), do: "the address is not a URL"
  def explain(:not_https), do: "the address must be https"
  def explain(:user_information), do: "the address must not carry user information"
  def explain(:no_host), do: "the address names no host"
  def explain(:port_not_allowed), do: "the port is not allowed by the installation"
end
