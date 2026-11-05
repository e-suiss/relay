defmodule Relay.Channels.Email.Resolver.Inet do
  @moduledoc """
  The production DNS resolver of the sending domain checks, on `:inet_res` with the node's resolver configuration. A lookup is a network call and is refused inside a database transaction (`Relay.NetworkGuard`).
  """

  @behaviour Relay.Channels.Email.Resolver

  @timeout 5_000

  @impl Relay.Channels.Email.Resolver
  def txt(name) do
    with {:ok, records} <- answers(name, :txt),
         do: {:ok, Enum.map(records, &strings/1)}
  end

  @impl Relay.Channels.Email.Resolver
  def cname(name) do
    with {:ok, [target | _rest]} <- answers(name, :cname),
         do: {:ok, host(target)}
  end

  @impl Relay.Channels.Email.Resolver
  def lookup(name, :mx) do
    with {:ok, records} <- answers(name, :mx),
         do: {:ok, Enum.map(records, fn {preference, host} -> {preference, host(host)} end)}
  end

  def lookup(name, type) when type in [:a, :aaaa], do: answers(name, type)

  defp answers(name, type) do
    :ok = Relay.NetworkGuard.check!(:dns)

    case :inet_res.resolve(String.to_charlist(name), :in, type, [], @timeout) do
      {:ok, message} ->
        message
        |> :inet_dns.msg(:anlist)
        |> Enum.filter(&(:inet_dns.rr(&1, :type) == type))
        |> Enum.map(&:inet_dns.rr(&1, :data))
        |> case do
          [] -> {:error, :no_data}
          records -> {:ok, records}
        end

      {:error, reason} ->
        {:error, error(reason)}
    end
  end

  defp error(:nxdomain), do: :nxdomain
  defp error({:nxdomain, _message}), do: :nxdomain
  defp error({:noanswer, _message}), do: :no_data
  defp error(:timeout), do: :timeout
  defp error(_other), do: :servfail

  defp strings(record), do: Enum.map(record, &:erlang.iolist_to_binary/1)

  defp host(name),
    do: name |> :erlang.iolist_to_binary() |> String.trim_trailing(".") |> String.downcase(:ascii)
end
