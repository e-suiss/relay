defmodule Relay.ScopeError do
  @moduledoc """
  Raised when the data access layer is asked to run a query without a tenant context, inside a transaction that did not establish one first, or when a returned row lies outside the established scope. It is a programming error, never a decision.
  """

  defexception [:reason, :message]

  @type reason :: :missing | :nested | :not_first | :row_outside_scope | :unknown_escape

  @impl true
  def exception(reason) when is_atom(reason),
    do: %__MODULE__{reason: reason, message: describe(reason)}

  defp describe(:missing), do: "query without a tenant context"
  defp describe(:nested), do: "a tenant context is already established in this process"
  defp describe(:not_first), do: "the tenant context must be the first statement of a transaction"
  defp describe(:row_outside_scope), do: "a returned row lies outside the established scope"
  defp describe(:unknown_escape), do: "not a declared escape hatch"
end
