defmodule Relay.Agents.SenderStanding do
  @moduledoc """
  What the recipient's side knows about a sender when a message arrives (AG-69): whether the sender is on the recipient's block list, and whether it is over the first contact rate. The trust label takes both as facts (`Relay.Agents.TrustLabel`).

  The implementation is configured as `config :relay, Relay.Agents, sender_standing: Module`. Until a block list and a first contact rate exist the default, `Relay.Agents.SenderStanding.None`, answers no to both. Both callbacks run outside any transaction, before the record is written.
  """

  @typedoc "The owner of the mailbox the message is for."
  @type recipient :: {:agent | :api_client, Relay.Id.t()}

  @typedoc "The sender as the message names it: its kind and its identifier."
  @type sender :: %{required(:kind) => atom(), required(:id) => String.t()}

  @doc "Whether the sender is on the block list of the recipient."
  @callback blocked?(Relay.Scope.t(), recipient(), sender()) :: boolean()

  @doc "Whether the sender is over the first contact rate with this message."
  @callback over_first_contact_rate?(Relay.Scope.t(), recipient(), sender()) :: boolean()

  # AG-69
  @doc "The configured implementation."
  @spec impl() :: module()
  def impl do
    :relay
    |> Application.get_env(Relay.Agents, [])
    |> Keyword.get(:sender_standing, Relay.Agents.SenderStanding.None)
  end
end
