defmodule Relay.Environment do
  @moduledoc """
  The two data planes of a tenant: `live` and `test`.
  """

  @type t :: :live | :test

  # TN-7
  @doc "Returns every environment."
  @spec all() :: [t(), ...]
  def all, do: [:live, :test]

  @doc "Casts an environment from its atom or its text form."
  @spec cast(term()) :: {:ok, t()} | {:error, Relay.Error.t()}
  def cast(environment) when environment in [:live, :test], do: {:ok, environment}
  def cast("live"), do: {:ok, :live}
  def cast("test"), do: {:ok, :test}
  def cast(_other), do: {:error, Relay.Error.new(:invalid_environment, "not an environment")}

  @doc "Returns the text form of an environment."
  @spec dump(t()) :: String.t()
  def dump(environment) when environment in [:live, :test], do: Atom.to_string(environment)
end
