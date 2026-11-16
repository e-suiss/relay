defmodule Relay.Webhooks.Egress.Resolver do
  @moduledoc """
  The DNS port of the egress boundary (WH-41 (1)). A resolver returns every A and AAAA address of a host name; the boundary validates each of them and connects only to an address it validated. Production resolves with `Relay.Webhooks.Egress.Resolver.Inet`; tests use a fake resolver.
  """

  @type error :: :nxdomain | :timeout | :failed

  @doc "Every A and AAAA address of the normalised host name `host`, within `timeout_ms` per record type."
  @callback resolve(host :: String.t(), timeout_ms :: pos_integer()) ::
              {:ok, [:inet.ip_address(), ...]} | {:error, error()}
end
