defmodule Relay.Limits do
  @moduledoc """
  The limits of the contract, read at compile time from `x-relay-limits` in `contracts/openapi/server.yaml`. The limits page, the request checks and every other limit in code read their values here; no limit value is written anywhere else. A duration limit is an ISO 8601 duration of weeks, days, hours, minutes and seconds in the contract and is read in seconds.
  """

  @path Path.expand("../../contracts/openapi/server.yaml", __DIR__)
  @external_resource @path

  @limits YamlElixir.read_from_file!(@path)["x-relay-limits"]
  @duration ~r/\AP(?!\z)(?:(\d+)W)?(?:(\d+)D)?(?:T(?=\d)(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?\z/
  @units [604_800, 86_400, 3_600, 60, 1]

  # API-4
  # X-37
  @doc "Every limit as the contract writes it."
  @spec all() :: map()
  def all, do: @limits

  # API-4
  # X-37
  @doc "The limit at `path` in `x-relay-limits`; raises for a path the contract does not have."
  @spec fetch!([String.t(), ...]) :: term()
  def fetch!(path) when is_list(path) and path != [] do
    case get_in(@limits, path) do
      nil -> raise ArgumentError, "no limit at #{Enum.join(path, ".")}"
      value -> value
    end
  end

  # API-8
  @doc "The duration limit at `path` in seconds; raises when it is not a fixed-length ISO 8601 duration."
  @spec seconds!([String.t(), ...]) :: non_neg_integer()
  def seconds!(path) do
    text = fetch!(path)

    case is_binary(text) and Regex.run(@duration, text) do
      [_ | parts] ->
        padded = parts ++ List.duplicate("", length(@units) - length(parts))

        padded
        |> Enum.zip(@units)
        |> Enum.reduce(0, fn
          {"", _unit}, acc -> acc
          {digits, unit}, acc -> acc + String.to_integer(digits) * unit
        end)

      _other ->
        raise ArgumentError, "the limit at #{Enum.join(path, ".")} is not a duration"
    end
  end
end
