defmodule Relay.Random do
  @moduledoc """
  Randomness port. Code draws random bytes and numbers only through this module so that tests can inject a deterministic source.
  """

  @callback bytes(pos_integer()) :: binary()
  @callback uniform(pos_integer()) :: pos_integer()

  # T-57
  @doc "Returns `n` random bytes from the configured source."
  @spec bytes(pos_integer()) :: binary()
  def bytes(n) when is_integer(n) and n > 0, do: impl().bytes(n)

  @doc "Returns a random integer in `1..n` from the configured source."
  @spec uniform(pos_integer()) :: pos_integer()
  def uniform(n) when is_integer(n) and n > 0, do: impl().uniform(n)

  defp impl, do: Application.fetch_env!(:relay, :random)
end
