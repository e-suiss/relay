defmodule Relay.Channels.RoutingTest do
  use ExUnit.Case, async: true

  alias Relay.ChannelDeclarations
  alias Relay.Channels.Routing

  defp declarations do
    {:ok, content} = ChannelDeclarations.compose()
    ChannelDeclarations.new(content, nil)
  end

  defp account(fields) do
    Map.merge(
      %{
        "id" => Relay.Id.generate(),
        "channel" => "push",
        "provider" => "fake",
        "role" => "primary",
        "priority" => 0,
        "weight" => 0,
        "verification_state" => "verified",
        "in_installation" => true,
        "processing_countries" => []
      },
      Map.new(fields, fn {key, value} -> {Atom.to_string(key), value} end)
    )
  end

  defp route(accounts, policy \\ %{}, senders \\ %{}),
    do: Routing.route(accounts, senders, &(&1 == "fake"), declarations(), policy)

  describe "CH-14 INV-43 verified route" do
    test "CH-14, INV-43: only a verified account of an activated adapter takes traffic" do
      verified = account(priority: 1)
      pending = account(verification_state: "pending")
      other = account(provider: "apns")

      assert {[^verified], excluded} = route([pending, verified, other])
      assert [%{reason: :unverified}, %{reason: :not_activated}] = excluded
      assert {[], [_, _]} = route([pending, other])
    end

    test "C-25, TN-10: a sending channel needs an approved sender identity on the account" do
      email = account(channel: "email")

      assert {[], [%{reason: :no_sender}]} = route([email])
      assert {[^email], []} = route([email], %{}, %{email["id"] => [%{"kind" => "email_domain"}]})
    end

    test "CH-6, TN-58: a domestic-only policy keeps an account processing abroad out of the route" do
      abroad = account(in_installation: false, processing_countries: ["DE"])
      home = account(in_installation: false, processing_countries: ["TR"])

      assert {[^home], [%{reason: :abroad}]} = route([abroad, home], %{domestic_country: "TR"})
      assert {[_, _], []} = route([abroad, home])
    end

    test "API-23: a provider override narrows the route and never widens it" do
      fake = account([])
      other = account(provider: "apns")

      assert {[^fake], [%{reason: :not_activated}]} = route([fake, other], %{provider: "fake"})

      assert {[], [%{reason: :not_requested}, %{reason: :not_activated}]} =
               route([fake, other], %{provider: "apns"})

      assert Routing.override_allowed?([fake], "fake")
      refute Routing.override_allowed?([fake], "apns")
    end
  end

  describe "CH-13 L-56 failover order" do
    test "CH-13: active-passive puts the primary accounts first, then the backups by priority" do
      backup = account(role: "backup", priority: 0)
      second = account(priority: 2)
      first = account(priority: 1)

      assert {[^first, ^second, ^backup], []} = route([backup, second, first])
    end

    test "L-56, CH-13: weights pick the first account deterministically in proportion" do
      a = account(weight: 1)
      b = account(weight: 3)

      firsts =
        for draw <- 0..3 do
          {[first, _second], []} = route([a, b], %{draw: draw})
          first
        end

      assert firsts == [a, b, b, b]
      assert {[^a, ^b], []} = route([a, b], %{draw: 4})
    end
  end
end
