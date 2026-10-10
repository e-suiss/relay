defmodule Relay.Random.Strong do
  @moduledoc "Cryptographically strong implementation of `Relay.Random`."

  @behaviour Relay.Random

  @impl true
  def bytes(n), do: :crypto.strong_rand_bytes(n)

  @impl true
  def uniform(n) do
    bits = max(1, ceil(:math.log2(n)))
    size = div(bits + 7, 8)
    limit = Integer.pow(2, size * 8) - rem(Integer.pow(2, size * 8), n)
    draw(n, size, limit)
  end

  defp draw(n, size, limit) do
    bits = size * 8
    <<value::unsigned-size(^bits)>> = :crypto.strong_rand_bytes(size)
    if value < limit, do: rem(value, n) + 1, else: draw(n, size, limit)
  end
end
