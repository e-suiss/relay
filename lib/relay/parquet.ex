defmodule Relay.Parquet do
  @moduledoc """
  Parquet files written and read through the `archive_port` program. Every column is an optional UTF-8 string holding the PostgreSQL text form of its value; a row is a list of binaries and `nil`s, one per column. A written or verified file is described by its row count, its size and the SHA-256 digest of the canonical encoding of its rows (`Relay.Parquet.Digest`), so a reader can prove that it holds exactly the rows that were written.

  The adapter is configured with `config :relay, Relay.Parquet, adapter: module` (default `Relay.Parquet.Port`); the remaining keys of that configuration are passed to the adapter as options, below the options of the call.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: [Digest]

  @type row :: [binary() | nil]
  @type summary :: %{rows: non_neg_integer(), digest: <<_::256>>, bytes: non_neg_integer()}
  @type verified :: %{
          rows: non_neg_integer(),
          digest: <<_::256>>,
          bytes: non_neg_integer(),
          columns: [String.t()]
        }
  @type reducer(acc) :: ([row()], acc -> acc)

  @callback write(Path.t(), [String.t(), ...], Enumerable.t(), keyword()) ::
              {:ok, summary()} | {:error, Relay.Error.t()}
  @callback verify(Path.t(), keyword()) :: {:ok, verified()} | {:error, Relay.Error.t()}
  @callback reduce(Path.t(), acc, reducer(acc), keyword()) ::
              {:ok, [String.t()], acc} | {:error, Relay.Error.t()}
            when acc: term()

  # OP-84
  # OP-86
  @doc "Writes `rows` (any enumerable of rows, consumed once and in order) to a new file at the absolute `path` with the given column names; refuses a path that exists."
  @spec write(Path.t(), [String.t(), ...], Enumerable.t(), keyword()) ::
          {:ok, summary()} | {:error, Relay.Error.t()}
  def write(path, columns, rows, opts \\ []) when is_binary(path) and is_list(columns),
    do: adapter(opts).write(path, columns, rows, options(opts))

  # OP-84
  @doc "Reads the file at `path` back and returns its summary with its column names under `:columns`."
  @spec verify(Path.t(), keyword()) :: {:ok, verified()} | {:error, Relay.Error.t()}
  def verify(path, opts \\ []) when is_binary(path),
    do: adapter(opts).verify(path, options(opts))

  # OP-84
  @doc "Reads the rows of the file at `path` in file order, in batches, folding each batch into `acc` with `fun`; returns the column names and the final accumulator."
  @spec reduce(Path.t(), acc, reducer(acc), keyword()) ::
          {:ok, [String.t()], acc} | {:error, Relay.Error.t()}
        when acc: term()
  def reduce(path, acc, fun, opts \\ []) when is_binary(path) and is_function(fun, 2),
    do: adapter(opts).reduce(path, acc, fun, options(opts))

  defp config, do: Application.get_env(:relay, __MODULE__, [])

  defp adapter(opts) do
    case Keyword.fetch(opts, :adapter) do
      {:ok, adapter} -> adapter
      :error -> Keyword.get(config(), :adapter, Relay.Parquet.Port)
    end
  end

  defp options(opts), do: config() |> Keyword.merge(opts) |> Keyword.delete(:adapter)
end
