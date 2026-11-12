defmodule Relay.Access.SubscriberTokenKeyStore do
  @moduledoc """
  Data access of the subscriber token signing keys (`relay.subscriber_token_keys`, IN-51). Rows are written only through the `relay_ops.subscriber_token_key_*` functions; no row is ever deleted.
  """

  alias Relay.Repo

  @escape :subscriber_token_keys
  @read "SELECT label, state, activated_at, verify_until FROM relay.subscriber_token_keys WHERE state IN ('current', 'previous')"

  # IN-51
  @doc "The rows of the current and the previous key as `[label, state, activated_at, verify_until]`."
  @spec active() :: {:ok, [list()]} | {:error, term()}
  def active do
    case Repo.unscoped_query(@escape, @read, []) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      {:error, error} -> {:error, error}
    end
  end

  # IN-51
  @doc "Calls `relay_ops.subscriber_token_key_<function>` with its parameters."
  @spec call(String.t(), list()) :: term()
  def call(function, params) when is_binary(function) and is_list(params),
    do: Repo.call_unscoped!(@escape, "relay_ops.subscriber_token_key_" <> function, params)
end
