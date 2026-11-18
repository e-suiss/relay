defmodule RelayTest.EmailResolver do
  @moduledoc "DNS for tests of the sending domain wizard: it answers from the zone the test process put with `put/1` (`{:txt, name}`, `{:cname, name}` or `{type, name}` keys), and every other name is `:nxdomain`. Nothing leaves the node."

  use Boundary, top_level?: true, deps: [], exports: []

  @doc "Sets the zone of the calling process."
  @spec put(map()) :: map() | nil
  def put(zone), do: Process.put(__MODULE__, zone)

  @doc "The TXT records of a name."
  @spec txt(String.t()) :: {:ok, term()} | {:error, atom()}
  def txt(name), do: answer({:txt, name})

  @doc "The CNAME target of a name."
  @spec cname(String.t()) :: {:ok, term()} | {:error, atom()}
  def cname(name), do: answer({:cname, name})

  @doc "The address or MX records of a name."
  @spec lookup(String.t(), atom()) :: {:ok, term()} | {:error, atom()}
  def lookup(name, type), do: answer({type, name})

  defp answer(key) do
    case Map.fetch(Process.get(__MODULE__, %{}), key) do
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, value} -> {:ok, value}
      :error -> {:error, :nxdomain}
    end
  end
end
