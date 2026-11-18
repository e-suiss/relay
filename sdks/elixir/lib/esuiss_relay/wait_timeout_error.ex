defmodule EsuissRelay.WaitTimeoutError do
  @moduledoc "The waitpoint was still open when the wait ran out; `waitpoint` is its last state."
  defexception [:waitpoint]

  @type t :: %__MODULE__{waitpoint: map() | nil}

  @impl true
  def message(_error), do: "the waitpoint is still open"
end
