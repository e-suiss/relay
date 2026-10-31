defmodule RelayWeb.Api.Beta do
  @moduledoc """
  Beta features (API-55): enabled per request with `Relay-Beta: <feature>[, <feature>]`, outside the version contract, and marked in the response with `"beta": true`. A feature that does not exist is `400 unsupported_beta_feature`.
  """

  @features []

  # API-55
  @doc "The beta features that exist."
  @spec features() :: [String.t()]
  def features, do: @features

  # API-55
  @doc "Reads the `Relay-Beta` header values against the known features."
  @spec parse([String.t()], [String.t()]) :: {:ok, [String.t()]} | {:error, Relay.Error.t()}
  def parse(values, known \\ @features) do
    requested =
      values
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case Enum.reject(requested, &(&1 in known)) do
      [] -> {:ok, Enum.uniq(requested)}
      _unknown -> {:error, Relay.Error.new(:unsupported_beta_feature, "unknown beta feature")}
    end
  end

  # API-55
  @doc "Marks a response body shaped by a beta feature."
  @spec mark(map()) :: map()
  def mark(body) when is_map(body), do: Map.put(body, "beta", true)
end
