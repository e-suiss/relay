defmodule Relay.Agents.TrustLabel do
  @moduledoc """
  The trust label of an incoming message (C-77, AG-38, AG-69): `blocked`, `spam`, `authenticated` or `unauthenticated`. Relay produces the label from facts about the sender and the carrier, never from the content of the message, and writes it as a typed field of the record and of the event that announces the record, so an agent or a routing rule decides on it before the agent is woken.

  The rules, the first that holds:

    * `blocked`: the sender is on the recipient's block list, or is suspended in Access;
    * `spam`: the carrying channel or provider flagged the message as unwanted, or the sender is over the first contact rate;
    * `authenticated`: the sender's identity is verified, by an Access token, a verified webhook signature, A2A authentication or an aligned DMARC pass of an e-mail;
    * `unauthenticated`: none of them.

  A record of a `spam` or `blocked` message is announced with `mailbox.record_flagged`, which only an endpoint that names the type receives; `mailbox.record_appended`, the hint that wakes an agent, is never written for it.
  """

  @labels ~w(blocked spam authenticated unauthenticated)a
  @proofs ~w(access_token webhook_signature a2a dmarc_aligned)a

  @type t :: :blocked | :spam | :authenticated | :unauthenticated
  @type proof :: :access_token | :webhook_signature | :a2a | :dmarc_aligned

  @typedoc "What is known about the sender and the carrier of one message; a fact that is absent is false."
  @type facts :: %{
          optional(:blocked) => boolean(),
          optional(:suspended) => boolean(),
          optional(:flagged) => boolean(),
          optional(:over_first_contact_rate) => boolean(),
          optional(:proof) => proof() | nil
        }

  # C-77
  @doc "The four labels, the strongest first."
  @spec labels() :: [t(), ...]
  def labels, do: @labels

  # AG-69
  @doc "The ways a sender's identity is verified."
  @spec proofs() :: [proof(), ...]
  def proofs, do: @proofs

  # AG-69
  # AG-38
  @doc "The label of a message from the facts about its sender and carrier."
  @spec assign(facts()) :: t()
  def assign(facts) when is_map(facts) do
    cond do
      fact?(facts, :blocked) or fact?(facts, :suspended) -> :blocked
      fact?(facts, :flagged) or fact?(facts, :over_first_contact_rate) -> :spam
      Map.get(facts, :proof) in @proofs -> :authenticated
      true -> :unauthenticated
    end
  end

  defp fact?(facts, key), do: Map.get(facts, key) == true

  # AG-38
  @doc "Whether a record with this label is announced with the hint that wakes an agent; a `spam` or `blocked` one is not."
  @spec wakes?(t()) :: boolean()
  def wakes?(label) when label in [:authenticated, :unauthenticated], do: true
  def wakes?(label) when label in [:spam, :blocked], do: false

  @doc "Casts a label from its text form."
  @spec cast(term()) :: {:ok, t()} | :error
  def cast("blocked"), do: {:ok, :blocked}
  def cast("spam"), do: {:ok, :spam}
  def cast("authenticated"), do: {:ok, :authenticated}
  def cast("unauthenticated"), do: {:ok, :unauthenticated}
  def cast(_other), do: :error
end
