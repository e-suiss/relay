defmodule Relay.Channels.Email.Resolver do
  @moduledoc """
  The DNS port of the sending domain checks (CH-36). A TXT answer keeps each record's character strings apart, so the checks can see how a long record is split. Production resolves with `:inet_res` (`Relay.Channels.Email.Resolver.Inet`); tests use a fake resolver.
  """

  @type error :: :nxdomain | :no_data | :servfail | :timeout
  @type type :: :a | :aaaa | :mx

  @doc "The TXT records of `name`, each as the list of its character strings."
  @callback txt(name :: String.t()) :: {:ok, [[binary()], ...]} | {:error, error()}

  @doc "The CNAME target of `name`, lowercased and without the final dot."
  @callback cname(name :: String.t()) :: {:ok, String.t()} | {:error, error()}

  @doc "The address or MX records of `name`; MX records are `{preference, host}`."
  @callback lookup(name :: String.t(), type()) :: {:ok, [term(), ...]} | {:error, error()}
end
