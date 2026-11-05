defmodule Relay.Channels.Email.ReputationTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Email.BulkRules
  alias Relay.Channels.Email.Bundled
  alias Relay.Channels.Email.Reputation
  alias Relay.Channels.Email.Warmup

  @hour 3_600_000

  defp params, do: Bundled.content("email_reputation")["reputation"]

  defp feed(circuit, now, event, count) do
    {circuit, _transitions} = Reputation.record(circuit, event, now, params(), count)
    circuit
  end

  defp sent(sent, delivered) do
    Reputation.new() |> feed(0, :sent, sent) |> feed(0, :delivered, delivered)
  end

  @plan %{
    "id" => "new_domain",
    "applies_to" => "domain",
    "until_day" => 10,
    "steps" => [
      %{"from_day" => 1, "daily_cap" => 500, "domain_hourly_cap" => 50},
      %{
        "from_day" => 4,
        "daily_cap" => 2000,
        "domain_hourly_cap" => 200,
        "domains" => %{"gmail.com" => 100}
      }
    ]
  }

  defp allow(today, usage, caps \\ %{}),
    do: Warmup.allowance(@plan, ~D[2026-11-01], today, usage, caps)

  defp usage(today, hour, domain),
    do: %{sent_today: today, sent_this_hour: hour, recipient_domain: domain}

  defp check(findings, dmarc \\ %{policy: "none"}), do: %{findings: findings, dmarc: dmarc}

  defp figures(extra \\ %{}),
    do: Map.merge(%{one_click_unsubscribe: true, unsubscribe_within_days: 2}, extra)

  describe "CH-41 reputation circuit" do
    test "CH-41: the bundled thresholds are the spec's starting values" do
      assert %{
               "window_ms" => 21_600_000,
               "warn_bounce_bp" => 200,
               "warn_complaint_bp" => 5,
               "stop_bounce_bp" => 400,
               "stop_complaint_bp" => 8
             } = params()
    end

    test "CH-41: a bounce rate at 2 % warns once and the stream still sends" do
      circuit = sent(1000, 1000) |> feed(1, :bounce, 19)
      assert circuit.state == :ok

      assert {circuit, [{:warning, %{bounce_bp: 200}}]} =
               Reputation.record(circuit, :bounce, 2, params())

      assert {circuit, []} = Reputation.record(circuit, :bounce, 3, params())
      assert circuit.state == :warning
      assert Reputation.admit(circuit) == :allow
    end

    test "CH-41: a bounce rate at 4 % stops the stream" do
      circuit = sent(1000, 1000) |> feed(1, :bounce, 39)

      assert {circuit, [{:stopped, %{bounces: 40, bounce_bp: 400}}]} =
               Reputation.record(circuit, :bounce, 2, params())

      assert circuit.state == :stopped
      assert Reputation.admit(circuit) == :paused
    end

    test "CH-37: the complaint rate is over mail delivered to the inbox" do
      circuit = sent(10_000, 2000)

      assert {%{state: :warning}, [{:warning, rates}]} =
               Reputation.record(circuit, :complaint, 2, params())

      assert rates.complaint_bp == 5

      circuit = sent(10_000, 10_000) |> feed(1, :complaint, 2)
      assert circuit.state == :ok
    end

    test "CH-41: a stopped circuit never closes by itself, however the rates fall" do
      circuit = sent(100, 100) |> feed(1, :complaint, 1)
      assert circuit.state == :stopped

      later = 7 * @hour
      circuit = circuit |> feed(later, :sent, 100_000) |> feed(later, :delivered, 100_000)

      assert circuit.state == :stopped
      assert Reputation.rates(circuit, later, params()).complaints == 0
      assert Reputation.admit(circuit) == :paused
    end

    test "CH-41: closing is an explicit action that clears the window and is audited" do
      circuit = sent(100, 100) |> feed(1, :bounce, 10)
      action = %{actor_ref: "operator:alice", reason: "list cleaned"}

      assert {:ok, closed, audit} = Reputation.close(circuit, action, 5000)
      assert closed.state == :ok
      assert Reputation.rates(closed, 5000, params()).sent == 0

      assert %{action: "email_reputation.closed", actor_ref: "operator:alice", closed_at: 5000} =
               audit

      assert audit.stop_rates.bounces == 10
      assert Reputation.close(closed, action, 6000) == {:error, :not_stopped}
    end

    test "CH-41: the window slides; counts older than six hours fall out" do
      circuit = sent(100, 100) |> feed(1, :bounce, 3)
      assert circuit.state == :warning

      now = 6 * @hour + 10 * 60_000
      assert %{sent: 0, bounces: 0} = Reputation.rates(circuit, now, params())

      {circuit, []} = Reputation.record(circuit, :sent, now, params())
      assert circuit.state == :ok
    end
  end

  describe "CH-42 warm-up" do
    test "CH-42: the step in force caps the day and the recipient domain's hour" do
      assert allow(~D[2026-11-01], usage(0, 0, "x.example")) == {:allow, 50}
      assert allow(~D[2026-11-03], usage(480, 0, "x.example")) == {:allow, 20}
      assert allow(~D[2026-11-05], usage(0, 0, "x.example")) == {:allow, 200}
      assert allow(~D[2026-11-05], usage(0, 30, "GMAIL.com")) == {:allow, 70}
    end

    test "CH-42: mail over the plan is deferred, never refused" do
      assert allow(~D[2026-11-02], usage(500, 0, "x.example")) == {:defer, :daily_cap}
      assert allow(~D[2026-11-02], usage(10, 50, "x.example")) == {:defer, :domain_hourly_cap}
    end

    test "CH-42: a provider's own caps are merged by the lower cap" do
      caps = %{daily_cap: 100, domain_hourly_cap: 10}

      assert allow(~D[2026-11-01], usage(0, 0, "x.example"), caps) == {:allow, 10}
    end

    test "CH-42: after the last day the plan is complete" do
      assert allow(~D[2026-11-11], usage(0, 0, "x.example")) == :complete

      assert Warmup.day(~D[2026-11-01], ~D[2026-11-10]) == 10
    end

    test "CH-42: the bundled data set carries no plan values; plans are added as data" do
      assert Bundled.content("email_warmup_plans")["plans"] == []
    end
  end

  describe "CH-37 bulk sender rules" do
    test "CH-37: the table covers Gmail, Yahoo, Microsoft and iCloud" do
      rules = Bundled.content("email_bulk_sender_rules")

      assert %{"provider" => "gmail"} = BulkRules.provider(rules, "GMAIL.com")
      assert %{"provider" => "yahoo"} = BulkRules.provider(rules, "yahoo.com")
      assert %{"provider" => "microsoft"} = BulkRules.provider(rules, "outlook.com")
      assert %{"provider" => "icloud"} = BulkRules.provider(rules, "icloud.com")
      assert BulkRules.provider(rules, "example.com") == nil

      assert %{"complaint_rate_max_bp" => 30, "complaint_rate_target_bp" => 10} =
               BulkRules.provider(rules, "gmail.com")["requirements"]
    end

    test "CH-37: a domain that meets the rules has no findings" do
      rules = Bundled.content("email_bulk_sender_rules")
      assert BulkRules.evaluate(rules, check([]), figures()) == []
    end

    test "CH-37: no DMARC record, a DKIM error and a slow unsubscribe are findings" do
      rules = Bundled.content("email_bulk_sender_rules")
      dkim = [%{severity: :error, code: :dkim_missing, subject: "s"}]
      slow = figures(%{unsubscribe_within_days: 3})
      findings = BulkRules.evaluate(rules, check(dkim, nil), slow)

      gmail = for %{provider: "gmail", code: code} <- findings, do: code
      assert :bulk_dkim in gmail
      assert :bulk_dmarc_policy in gmail
      assert :bulk_unsubscribe_delay in gmail
      refute :bulk_spf in gmail
    end

    test "CH-37: the complaint rate warns at the target and fails at the maximum" do
      rules = Bundled.content("email_bulk_sender_rules")

      assert [%{severity: :warning, code: :bulk_complaint_target}] =
               rules
               |> BulkRules.evaluate(check([]), figures(%{complaint_bp: %{"gmail" => 10}}))
               |> Enum.filter(&(&1.provider == "gmail"))

      assert [%{severity: :error, code: :bulk_complaint_rate}] =
               rules
               |> BulkRules.evaluate(check([]), figures(%{complaint_bp: %{"gmail" => 30}}))
               |> Enum.filter(&(&1.provider == "gmail"))
    end
  end
end
