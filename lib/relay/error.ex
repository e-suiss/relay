defmodule Relay.Error do
  @moduledoc """
  Typed error returned as `{:error, %Relay.Error{}}`. A decision not to send is not an error; see `Relay.Decision`.
  """

  @enforce_keys [:code, :message]
  defstruct [:code, :message, details: %{}]

  @type t :: %__MODULE__{code: atom(), message: String.t(), details: map()}

  # T-58
  @doc "Builds an error with a machine-readable code and a human-readable message."
  @spec new(atom(), String.t(), map()) :: t()
  def new(code, message, details \\ %{})
      when is_atom(code) and is_binary(message) and is_map(details) do
    %__MODULE__{code: code, message: message, details: details}
  end
end
