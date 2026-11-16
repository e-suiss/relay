defmodule Relay.Webhooks.Egress.Resolver.Inet do
  @moduledoc """
  The production resolver of the egress boundary, on `:inet_res` with the node's resolver configuration. The name is looked up as an absolute name, so no search domain is appended to it. A lookup is a network call and is refused inside a database transaction (`Relay.NetworkGuard`).
  """

  @behaviour Relay.Webhooks.Egress.Resolver

  # WH-41 (1)
  @impl Relay.Webhooks.Egress.Resolver
  def resolve(host, timeout_ms) when is_binary(host) and is_integer(timeout_ms) do
    :ok = Relay.NetworkGuard.check!(:dns)
    name = String.to_charlist(host <> ".")

    case {answers(name, :a, timeout_ms), answers(name, :aaaa, timeout_ms)} do
      {{:ok, [_first | _rest] = ipv4}, {:ok, ipv6}} -> {:ok, ipv4 ++ ipv6}
      {{:ok, [_first | _rest] = ipv4}, {:error, _reason}} -> {:ok, ipv4}
      {_ipv4, {:ok, [_first | _rest] = ipv6}} -> {:ok, ipv6}
      {{:error, reason}, _ipv6} -> {:error, reason}
      {_ipv4, {:error, reason}} -> {:error, reason}
      {{:ok, []}, {:ok, []}} -> {:error, :nxdomain}
    end
  end

  defp answers(name, type, timeout_ms) do
    case :inet_res.resolve(name, :in, type, [], timeout_ms) do
      {:ok, message} ->
        {:ok, addresses(:inet_dns.msg(message, :anlist), type)}

      {:error, reason} ->
        {:error, error(reason)}
    end
  end

  defp addresses(records, type) do
    for record <- records, :inet_dns.rr(record, :type) == type, do: :inet_dns.rr(record, :data)
  end

  defp error(:nxdomain), do: :nxdomain
  defp error({:nxdomain, _message}), do: :nxdomain
  defp error(:timeout), do: :timeout
  defp error(_other), do: :failed
end
