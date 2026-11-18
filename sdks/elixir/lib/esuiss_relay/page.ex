defmodule EsuissRelay.Page do
  @moduledoc """
  One page of a cursor-paginated list (`object: list`).

  `data`, `has_more`, `next_cursor` and `previous_cursor` are the page as Relay returned it.
  The page is also an `Enumerable` over every item of the list, fetched lazily: a following page
  is requested only when the items already read are used up, so `Enum.take(page, 10)` never
  reads further than it needs. A list started with `starting_after` (or no cursor) goes forward
  with `starting_after: next_cursor`; a list started with `ending_before` goes backward with
  `ending_before: previous_cursor` and yields each page's items in reverse order. A failed
  request for a later page raises its `EsuissRelay.Error`.
  """

  alias EsuissRelay.Client
  alias EsuissRelay.Operation

  @enforce_keys [:data, :has_more, :next_cursor]
  defstruct [
    :data,
    :has_more,
    :next_cursor,
    :previous_cursor,
    :client,
    :operation,
    direction: :forward,
    path_values: [],
    opts: []
  ]

  @type t :: %__MODULE__{
          data: [term()],
          has_more: boolean(),
          next_cursor: String.t() | nil,
          previous_cursor: String.t() | nil,
          client: Client.t() | nil,
          operation: Operation.t() | nil,
          direction: :forward | :backward,
          path_values: [term()],
          opts: keyword()
        }

  @doc false
  @spec new(Client.t(), Operation.t(), [term()], keyword(), map()) :: t()
  def new(client, operation, path_values, opts, body) do
    %__MODULE__{
      data: Map.get(body, "data", []),
      has_more: Map.get(body, "has_more", false) == true,
      next_cursor: Map.get(body, "next_cursor"),
      previous_cursor: Map.get(body, "previous_cursor"),
      client: client,
      operation: operation,
      direction: if(opts[:ending_before] != nil, do: :backward, else: :forward),
      path_values: path_values,
      opts: opts
    }
  end

  # API-56
  @doc "The following page in the direction of the list, or `nil` when this is the last one."
  @spec next(t()) :: {:ok, t() | nil} | {:error, EsuissRelay.Error.t()}
  def next(%__MODULE__{direction: :backward, previous_cursor: nil}), do: {:ok, nil}

  def next(%__MODULE__{direction: :backward} = page) do
    opts =
      page.opts
      |> Keyword.delete(:starting_after)
      |> Keyword.put(:ending_before, page.previous_cursor)

    Client.call(page.client, page.operation, page.path_values, nil, opts)
  end

  def next(%__MODULE__{has_more: false}), do: {:ok, nil}
  def next(%__MODULE__{next_cursor: nil}), do: {:ok, nil}

  def next(%__MODULE__{} = page) do
    opts =
      page.opts
      |> Keyword.delete(:ending_before)
      |> Keyword.put(:starting_after, page.next_cursor)

    Client.call(page.client, page.operation, page.path_values, nil, opts)
  end

  @doc "The items of this page in the order the list yields them."
  @spec items(t()) :: [term()]
  def items(%__MODULE__{direction: :backward, data: data}), do: Enum.reverse(data)
  def items(%__MODULE__{data: data}), do: data

  # API-56
  @doc "A lazy stream of every item from this page on."
  @spec stream(t()) :: Enumerable.t()
  def stream(%__MODULE__{} = page) do
    Stream.resource(fn -> {:emit, page} end, &step/1, fn _state -> :ok end)
  end

  defp step(:done), do: {:halt, :done}
  defp step({:emit, current}), do: {items(current), {:fetch, current}}

  defp step({:fetch, current}) do
    case next(current) do
      {:ok, nil} -> {:halt, :done}
      {:ok, following} -> {items(following), {:fetch, following}}
      {:error, error} -> raise error
    end
  end

  defimpl Enumerable do
    def count(_page), do: {:error, __MODULE__}
    def member?(_page, _value), do: {:error, __MODULE__}
    def slice(_page), do: {:error, __MODULE__}
    def reduce(page, acc, fun), do: Enumerable.reduce(@for.stream(page), acc, fun)
  end
end
