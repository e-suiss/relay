defmodule RelayTest.WebhookResolver do
  @moduledoc "DNS for tests of webhook registration: `blocked.example.com` resolves to a private address, `missing.example.com` does not resolve, and every other name resolves to a public address. Nothing leaves the node."

  use Boundary, top_level?: true, deps: [Relay], exports: []

  @doc "Resolves a host name as the module documentation says."
  @spec resolve(String.t(), pos_integer()) ::
          {:ok, [:inet.ip_address(), ...]} | {:error, :nxdomain}
  def resolve("blocked.example.com", _timeout_ms), do: {:ok, [{203, 0, 114, 7}, {10, 0, 0, 7}]}
  def resolve("missing.example.com", _timeout_ms), do: {:error, :nxdomain}
  def resolve(_host, _timeout_ms), do: {:ok, [{203, 0, 114, 7}]}
end
