defmodule Relay.LogRedactor do
  @moduledoc """
  LoggerJSON redactor that replaces every `Relay.Redacted` value, at any depth, and the arguments of every stack trace frame before a log line is encoded.
  """

  @behaviour LoggerJSON.Redactor

  @replacement "[REDACTED]"

  # T-46
  # T-63
  @impl true
  def redact(_key, value, _opts), do: scrub(value)

  @doc false
  @spec scrub(term()) :: term()
  def scrub(%Relay.Redacted{}), do: @replacement

  def scrub({module, function, args, location})
      when is_atom(module) and is_atom(function) and is_list(args) and is_list(location),
      do: {module, function, length(args), location}

  def scrub(%_{} = struct), do: struct |> Map.from_struct() |> scrub()
  def scrub(%{} = map), do: Map.new(map, fn {key, value} -> {key, scrub(value)} end)
  def scrub(list) when is_list(list), do: Enum.map(list, &scrub/1)

  def scrub(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> scrub() |> List.to_tuple()

  def scrub(value), do: value
end
