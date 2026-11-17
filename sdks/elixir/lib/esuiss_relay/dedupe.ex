defmodule EsuissRelay.Dedupe do
  @moduledoc """
  A bounded set of the identifiers already handled. Relay delivers at least once, so a reader
  drops what it has seen; the oldest identifiers leave the set once it holds `limit` of them.
  """

  @enforce_keys [:seen, :order, :limit]
  defstruct [:seen, :order, :limit, size: 0]

  @type t :: %__MODULE__{
          seen: MapSet.t(),
          order: :queue.queue(),
          size: non_neg_integer(),
          limit: pos_integer()
        }

  @doc "An empty set that remembers at most `limit` identifiers."
  @spec new(pos_integer()) :: t()
  def new(limit \\ 10_000) when is_integer(limit) and limit > 0,
    do: %__MODULE__{seen: MapSet.new(), order: :queue.new(), limit: limit}

  @doc "`{true, set}` for an identifier seen for the first time, `{false, set}` otherwise."
  @spec first?(t(), term()) :: {boolean(), t()}
  def first?(%__MODULE__{} = dedupe, id) do
    if MapSet.member?(dedupe.seen, id) do
      {false, dedupe}
    else
      {true, dedupe |> remember(id) |> trim()}
    end
  end

  defp remember(dedupe, id) do
    %{
      dedupe
      | seen: MapSet.put(dedupe.seen, id),
        order: :queue.in(id, dedupe.order),
        size: dedupe.size + 1
    }
  end

  defp trim(%{size: size, limit: limit} = dedupe) when size <= limit, do: dedupe

  defp trim(dedupe) do
    {{:value, oldest}, order} = :queue.out(dedupe.order)
    %{dedupe | seen: MapSet.delete(dedupe.seen, oldest), order: order, size: dedupe.size - 1}
  end
end
