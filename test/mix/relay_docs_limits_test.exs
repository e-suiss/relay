defmodule RelayDev.LimitsPageTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Relay.Docs.Limits, as: LimitsTask
  alias RelayDev.LimitsPage

  @moduletag :tmp_dir

  defp page, do: LimitsPage.render(File.cwd!())

  describe "X-49 X-37 generated limits page" do
    test "X-37, API-4: every limit of the contract appears with its value" do
      page = page()
      recipients = Relay.Limits.fetch!(["event", "max_recipients"])

      assert page =~ "| `event.max_recipients` | #{recipients} |"
      assert page =~ "| `idempotency_key_ttl_hours` | 24 |"
      assert page =~ "| `webhook.retry_schedule.default` | PT0S, PT5S"
      refute page =~ "x-relay-choice"
    end

    test "AG-53: the agent resource limits have their own section" do
      [_before, agents] = String.split(page(), "## Agent resource limits", parts: 2)
      [agents | _rest] = String.split(agents, "## Retry schedules", parts: 2)

      assert agents =~ "| `waitpoint.max_wait` | P30D |"
      assert agents =~ "| `mailbox.redeliveries.max` |"
      assert agents =~ "| `agent_ceiling.per_hour` | 100 |"
    end

    test "X-37: the retry schedules come from the contract and the channel_parameters data set" do
      page = page()

      assert page =~ "### Webhook deliveries"
      assert page =~ "The default schedule waits PT0S, PT5S, PT5M"
      assert page =~ "From `channel_parameters` version v"
      assert page =~ "| `push` | `apns` | `transient` | `server_error` |  | exponential |"
      assert page =~ "| exponential | 30 min | 2 h |  | 5 |"
      assert page =~ "`permanent_target`"
    end

    test "API-4, API-73: every error code of the catalog is listed with its retry rule" do
      page = page()

      for code <- Relay.Api.ErrorCatalog.codes() do
        assert page =~ "| `#{code}` |", "#{code} is missing"
      end

      assert page =~ "| `rate_limited` | 429 | yes | end of the rate limit window |"
    end

    test "X-38, INV-60: the page carries the one guarantee sentence and no forbidden claim" do
      page = page()

      assert page =~ LimitsPage.guarantee_sentence()

      assert LimitsPage.guarantee_sentence() =~
               "at-least-once delivery with durable idempotency, giving effectively-once"

      claims = "conformance/catalog/claims.json" |> File.read!() |> Jason.decode!()

      for %{"pattern" => pattern} <- claims do
        refute Regex.match?(Regex.compile!(pattern, "iu"), page), pattern
      end
    end

    test "X-49: the task writes the page and its check fails on a stale copy", %{tmp_dir: dir} do
      out = Path.join(dir, "reference/limits.md")
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      LimitsTask.run([out])
      assert File.read!(out) == page()
      LimitsTask.run(["--check", out])

      File.write!(out, "stale\n")
      assert_raise Mix.Error, ~r/stale/, fn -> LimitsTask.run(["--check", out]) end
      assert_raise Mix.Error, ~r/usage/, fn -> LimitsTask.run([]) end
    end
  end
end
