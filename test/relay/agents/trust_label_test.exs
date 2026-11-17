defmodule Relay.Agents.TrustLabelTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Agents.SenderStanding
  alias Relay.Agents.TrustLabel

  describe "AG-69 the assignment rules" do
    test "AG-69: a sender on the block list or suspended in Access is blocked before anything" do
      assert TrustLabel.assign(%{blocked: true}) == :blocked
      assert TrustLabel.assign(%{suspended: true}) == :blocked

      all = %{blocked: true, flagged: true, over_first_contact_rate: true, proof: :access_token}
      assert TrustLabel.assign(all) == :blocked
      assert TrustLabel.assign(Map.merge(all, %{blocked: false, suspended: true})) == :blocked
    end

    test "AG-69: a flagged message or a sender over the first contact rate is spam" do
      assert TrustLabel.assign(%{flagged: true}) == :spam
      assert TrustLabel.assign(%{over_first_contact_rate: true}) == :spam
      assert TrustLabel.assign(%{flagged: true, proof: :a2a}) == :spam
    end

    test "AG-69: every way of verifying the sender's identity is authenticated" do
      assert TrustLabel.proofs() == [:access_token, :webhook_signature, :a2a, :dmarc_aligned]

      for proof <- TrustLabel.proofs(),
          do: assert(TrustLabel.assign(%{proof: proof}) == :authenticated)
    end

    test "AG-69: without any of them the message is unauthenticated" do
      assert TrustLabel.assign(%{}) == :unauthenticated
      assert TrustLabel.assign(%{proof: nil, blocked: false, flagged: false}) == :unauthenticated
      assert TrustLabel.assign(%{proof: :claimed}) == :unauthenticated
      assert TrustLabel.assign(%{blocked: "true", flagged: 1}) == :unauthenticated
    end

    property "AG-69: the label follows the order blocked, spam, authenticated, unauthenticated" do
      check all(
              blocked <- boolean(),
              suspended <- boolean(),
              flagged <- boolean(),
              over <- boolean(),
              proof <- member_of([nil | TrustLabel.proofs()])
            ) do
        label =
          TrustLabel.assign(%{
            blocked: blocked,
            suspended: suspended,
            flagged: flagged,
            over_first_contact_rate: over,
            proof: proof
          })

        expected =
          cond do
            blocked or suspended -> :blocked
            flagged or over -> :spam
            proof != nil -> :authenticated
            true -> :unauthenticated
          end

        assert label == expected
        assert label in TrustLabel.labels()
      end
    end
  end

  describe "AG-38 C-77 the label and waking" do
    test "C-77: the label has four values and a text form" do
      assert TrustLabel.labels() == [:blocked, :spam, :authenticated, :unauthenticated]

      for label <- TrustLabel.labels(),
          do: assert(TrustLabel.cast(Atom.to_string(label)) == {:ok, label})

      assert TrustLabel.cast("trusted") == :error
    end

    test "AG-38: a spam or blocked message is not announced with the hint that wakes an agent" do
      assert TrustLabel.wakes?(:authenticated)
      assert TrustLabel.wakes?(:unauthenticated)
      refute TrustLabel.wakes?(:spam)
      refute TrustLabel.wakes?(:blocked)
    end

    test "AG-69: without a block list and a first contact rate no sender is blocked or over it" do
      scope = %Relay.Scope{tenant_id: Relay.Id.generate(), environment: :test}
      owner = {:agent, Relay.Id.generate()}
      sender = %{kind: :agent, id: "agent-1"}

      assert SenderStanding.impl() == SenderStanding.None
      refute SenderStanding.None.blocked?(scope, owner, sender)
      refute SenderStanding.None.over_first_contact_rate?(scope, owner, sender)
    end
  end
end
