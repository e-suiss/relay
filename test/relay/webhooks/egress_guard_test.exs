defmodule Relay.Webhooks.EgressGuardTest do
  use Relay.DataCase, async: false

  alias Relay.NetworkGuard
  alias Relay.Repo
  alias Relay.Webhooks.Egress
  alias Relay.Webhooks.Egress.Policy

  @options [connect_timeout_ms: 5_000, total_timeout_ms: 20_000, max_response_bytes: 8_192]

  describe "WH-41 no egress inside a transaction" do
    test "WH-41: no name is resolved and no connection is opened inside a database transaction" do
      {:ok, policy} = Policy.new(deployment: :saas)
      named = %{method: "POST", url: "https://hooks.example.com/relay", headers: [], body: "{}"}
      literal = %{named | url: "https://203.0.114.10/relay"}

      Repo.transaction(fn ->
        assert_raise NetworkGuard.Error, ~r/:dns/, fn ->
          Egress.request(policy, named, @options)
        end

        assert_raise NetworkGuard.Error, ~r/:dns/, fn ->
          Egress.dns_findings(policy, named.url, dns_timeout_ms: 1_000)
        end

        assert_raise NetworkGuard.Error, ~r/:http/, fn ->
          Egress.request(policy, literal, @options)
        end

        assert {:error, %{class: :blocked}} =
                 Egress.request(policy, %{named | url: "https://10.0.0.5/"}, @options)
      end)
    end
  end
end
