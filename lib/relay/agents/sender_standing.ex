defmodule Relay.Agents.SenderStanding do
  @moduledoc """
  What the recipient's side knows about a sender when a message arrives (AG-69): whether the sender is on the recipient's block list, and whether it is over the first contact rate. The trust label takes both as facts (`Relay.Agents.TrustLabel`).

  The implementation is configured as `config :relay, Relay.Agents, sender_standing: Module`; the default is `Relay.Agents.SenderStanding.Registered`, which reads the block list and the first contact rate of registered agents. The callback runs outside any transaction, before the record is written.
  """

  @typedoc "The owner of the mailbox the message is for."
  @type recipient :: {:agent | :api_client, Relay.Id.t()}

  @typedoc "The sender as the message names it: its kind and its identifier."
  @type sender :: %{required(:kind) => atom(), required(:id) => String.t()}

  @type t :: %{blocked: boolean(), over_first_contact_rate: boolean()}

  @doc "Whether the sender is on the block list of the recipient and whether it is over the first contact rate."
  @callback standing(Relay.Scope.t(), recipient(), sender()) :: {:ok, t()} | {:error, term()}

  # AG-69
  @doc "The configured implementation."
  @spec impl() :: module()
  def impl do
    :relay
    |> Application.get_env(Relay.Agents, [])
    |> Keyword.get(:sender_standing, Relay.Agents.SenderStanding.Registered)
  end
end
