defmodule Relay.Redacted do
  @moduledoc """
  Wrapper for secrets, contact addresses and message content. The wrapped value never appears in `inspect`, logs, JSON or string interpolation; reading it requires an explicit `expose/1`.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @opaque t :: %__MODULE__{value: term()}

  # T-58
  # T-46
  @doc "Wraps a sensitive value."
  @spec wrap(term()) :: t()
  def wrap(%__MODULE__{} = redacted), do: redacted
  def wrap(value), do: %__MODULE__{value: value}

  @doc "Returns the wrapped value. Every call site is a deliberate disclosure point."
  @spec expose(t()) :: term()
  def expose(%__MODULE__{value: value}), do: value

  defimpl Inspect do
    def inspect(_redacted, _opts), do: "#Relay.Redacted<**redacted**>"
  end

  defimpl Jason.Encoder do
    def encode(_redacted, opts), do: Jason.Encode.string("**redacted**", opts)
  end
end
