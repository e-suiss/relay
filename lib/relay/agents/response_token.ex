defmodule Relay.Agents.ResponseToken do
  @moduledoc """
  The response token of a decision request (INV-33, AG-30, AG-31): a bearer value that lets one responder answer one waitpoint from a human channel. It is single-use, short-lived, scoped to one waitpoint and one responder, and a new one is minted for every message that carries it, so a resend rotates it. A token is handed only to the delivery of a human channel; no API response, event or mailbox record returned to the waiter carries it.

  Until the response intake serves tokens, `mint/3` refuses and a decision request is delivered without a response link.
  """

  @type token :: String.t()

  @doc "Mints the response token of `recipient_id` for `waitpoint_id`."
  @callback mint(Relay.Scope.t(), Relay.Id.t(), Relay.Id.t()) :: {:ok, token()} | {:error, atom()}

  # INV-33
  # AG-30
  # AG-31
  @doc "Mints the response token of the responder `recipient_id` for the waitpoint `waitpoint_id`, outside any transaction; `{:error, :response_token_unavailable}` while no token is served."
  @spec mint(Relay.Scope.t(), Relay.Id.t(), Relay.Id.t()) :: {:ok, token()} | {:error, atom()}
  def mint(%Relay.Scope{}, <<_::128>>, <<_::128>>), do: {:error, :response_token_unavailable}
end
