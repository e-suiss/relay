defmodule Relay.Webhooks.OutcomeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Webhooks.Outcome

  @now ~U[2026-11-16 08:00:00Z]

  defp http(status, headers \\ []) do
    receipt = %{kind: :http, status: status, headers: headers, body: "", duration_ms: 12}
    Outcome.classify({:ok, Map.put(receipt, :address, "203.0.114.10")}, @now)
  end

  defp failure(class) do
    failure = %{class: class, reason: "reason", duration_ms: 12, address: nil}
    Outcome.classify({:error, failure}, @now)
  end

  describe "WH-23 status code table" do
    test "WH-23: every 2xx is a delivery" do
      for status <- 200..299 do
        assert %Outcome{result: :delivered, breaker: :success, endpoint: :none, status: ^status} =
                 http(status)
      end
    end

    test "WH-23: a 3xx is not followed and not retried, and the endpoint gets a health warning" do
      for status <- 300..399 do
        outcome = http(status, [{"location", "https://elsewhere.example/hook"}])

        assert %Outcome{result: :failed_permanent, reason: :redirect_not_followed} = outcome
        assert {outcome.endpoint, outcome.breaker} == {:warn, :neutral}
      end
    end

    test "WH-23: a 410 fails the message for good and disables the endpoint at once" do
      assert %Outcome{result: :failed_permanent, reason: :gone, endpoint: :disable} = http(410)
    end

    test "WH-23: 401, 407, 409, 429 and every 5xx are retried" do
      for status <- [401, 407, 409, 429] ++ Enum.to_list(500..599) do
        outcome = http(status)

        assert %Outcome{result: :retry, reason: :http_status, breaker: :failure} = outcome
        assert outcome.endpoint == :none
      end
    end

    test "WH-23: every other 4xx fails the message for good without touching the endpoint" do
      for status <- Enum.to_list(400..499) -- [401, 407, 409, 410, 429] do
        assert %Outcome{result: :failed_permanent, reason: :http_status, endpoint: :none} =
                 http(status)
      end
    end

    test "WH-23: connection errors, timeouts and TLS errors are retried" do
      retried = [
        connect: :connection_error,
        dns: :dns_error,
        timeout: :timeout,
        tls: :tls_error,
        protocol: :protocol_error
      ]

      for {class, reason} <- retried do
        assert %Outcome{result: :retry, reason: ^reason, breaker: :failure, status: nil} =
                 failure(class)
      end
    end

    property "WH-23: every status has exactly one decision, and only a 2xx is a delivery" do
      check all status <- integer(100..599) do
        outcome = http(status)
        delivered? = outcome.result == :delivered
        success? = status in 200..299
        disabled? = outcome.endpoint == :disable
        gone? = status == 410

        assert outcome.result in [:delivered, :retry, :failed_permanent]
        assert delivered? == success?
        assert disabled? == gone?
      end
    end
  end

  describe "WH-25 WH-26 response headers" do
    test "WH-25: Retry-After is read on 429 and 503 only, as seconds or as a date" do
      for status <- [429, 503] do
        assert http(status, [{"retry-after", "120"}]).retry_after_ms == 120_000
        assert http(status, [{"Retry-After", " 0 "}]).retry_after_ms == 0
        assert http(status).retry_after_ms == nil

        date = [{"retry-after", "Mon, 16 Nov 2026 08:10:00 GMT"}]
        assert http(status, date).retry_after_ms == 600_000

        past = [{"retry-after", "Mon, 16 Nov 2026 07:00:00 GMT"}]
        assert http(status, past).retry_after_ms == 0

        for value <- ["soon", "-5", "1.5", "99999999999", "Mon, 31 Feb 2026 08:10:00 GMT"] do
          assert http(status, [{"retry-after", value}]).retry_after_ms == nil
        end
      end

      for status <- [500, 502, 401, 409] do
        assert http(status, [{"retry-after", "120"}]).retry_after_ms == nil
      end
    end

    test "WH-26: the consumer's abort header fails the message for good" do
      abort = [{"Webhook-Delivery", " Abort-Message "}]

      for status <- [400, 401, 429, 500, 503, 302] do
        outcome = http(status, abort)

        assert %Outcome{result: :failed_permanent, reason: :aborted_by_consumer} = outcome
        assert {outcome.endpoint, outcome.breaker} == {:none, :neutral}
      end

      assert %Outcome{result: :delivered} = http(200, abort)
      assert %Outcome{reason: :gone, endpoint: :disable} = http(410, abort)
      assert %Outcome{result: :retry} = http(500, [{"webhook-delivery", "continue"}])
    end
  end

  describe "WH-18 destinations without HTTP" do
    test "WH-18: a durable write that was acknowledged is a delivery" do
      receipt = %{kind: :write, duration_ms: 3, address: "198.51.101.7"}

      assert %Outcome{result: :delivered, reason: :acknowledged, breaker: :success} =
               Outcome.classify({:ok, receipt}, @now)
    end

    test "WH-18: an unavailable destination is retried, a rejection is dead-lettered" do
      assert %Outcome{result: :retry, reason: :destination_unavailable, breaker: :failure} =
               failure(:unavailable)

      assert %Outcome{result: :retry, reason: :credentials_unavailable, breaker: :neutral} =
               failure(:credentials)

      assert %Outcome{result: :dead_lettered, reason: :destination_rejected} = failure(:rejected)
      assert %Outcome{result: :dead_lettered, reason: :destination_invalid} = failure(:invalid)

      assert %Outcome{result: :dead_lettered, reason: :destination_blocked, endpoint: :warn} =
               failure(:blocked)
    end
  end

  describe "WH-27 terminal states" do
    test "WH-27: the terminal states are distinct, and all but delivered stay in the dead letter queue" do
      states = Outcome.terminal_states()

      expected = [
        :delivered,
        :failed_permanent,
        :exhausted,
        :expired,
        :window_exceeded,
        :dead_lettered,
        :cancelled
      ]

      assert states == expected
      assert Enum.uniq(states) == states
      assert Enum.reject(states, &Outcome.dead_letter?/1) == [:delivered]
    end

    test "WH-27: one attempt ends a message only as delivered, failed for good or dead-lettered" do
      results = 100..599 |> Enum.map(&http(&1).result) |> Enum.uniq()

      assert Enum.sort(results) == [:delivered, :failed_permanent, :retry]

      for result <- [:delivered, :failed_permanent, :dead_lettered] do
        assert result in Outcome.terminal_states()
      end

      refute :retry in Outcome.terminal_states()
    end
  end
end
