defmodule Relay.Webhooks.HealthTest do
  use ExUnit.Case, async: true

  alias Relay.Webhooks.Health
  alias Relay.Webhooks.Outcome
  alias Relay.Webhooks.Settings

  @start ~U[2026-11-16 00:00:00.000000Z]
  @row %{
    "breaker_state" => "closed",
    "breaker_opened_at" => nil,
    "breaker_open_seconds" => nil,
    "breaker_retry_at" => nil,
    "breaker_trips" => 0,
    "consecutive_failures" => 0,
    "failing_since" => nil,
    "failure_count" => 0,
    "last_failure_at" => nil,
    "last_failure_code" => nil,
    "last_response_status" => nil,
    "warned_at" => nil,
    "last_success_at" => nil,
    "last_attempt_at" => nil,
    "failing_clock_at" => nil
  }
  @failure %Outcome{result: :retry, reason: :http_status, status: 503, breaker: :neutral}
  @success %Outcome{result: :delivered, reason: :accepted, status: 200, breaker: :success}

  defp hours(n), do: DateTime.add(@start, n * 3600, :second)

  defp fail(row, hour, auto \\ true),
    do: Health.record(row, @failure, :allow, auto, hours(hour), Settings.health())

  defp failing(hours, auto \\ true) do
    Enum.reduce(hours, {@row, []}, fn hour, {row, _effects} -> fail(row, hour, auto) end)
  end

  describe "WH-36 automatic disable" do
    test "WH-36 (1): the clock starts only with more than one failure within 24 hours and 12 hours between the first and the last" do
      {one, []} = failing([0])
      assert one["failing_since"] == hours(0)
      assert one["failing_clock_at"] == nil

      {close, []} = failing([0, 6])
      assert close["failing_clock_at"] == nil

      {apart, []} = failing([0, 30])
      assert apart["failing_clock_at"] == nil

      {started, []} = failing([0, 6, 13])
      assert started["failing_clock_at"] == hours(13)
      assert Health.disable_at(started, true, Settings.health()) == hours(120)
      assert Health.disable_at(started, false, Settings.health()) == nil
    end

    test "WH-36 (1), WH-36 (3): the tenant is warned once at hour 72 and the endpoint is disabled after 5 days" do
      {row, []} = failing([0, 6, 13, 24, 48, 71])
      {warned, [:warn]} = fail(row, 72)
      assert warned["warned_at"] == hours(72)
      {later, []} = fail(warned, 96)
      {_row, [:disable_failing]} = fail(later, 120)
    end

    test "WH-36 (1): one successful delivery resets the clock" do
      {row, []} = failing([0, 6, 13, 24])
      {reset, []} = Health.record(row, @success, :allow, true, hours(30), Settings.health())
      assert reset["failing_since"] == nil
      assert reset["failure_count"] == 0
      assert reset["failing_clock_at"] == nil
      assert reset["last_success_at"] == hours(30)
      {again, []} = fail(reset, 130)
      assert again["failing_since"] == hours(130)
    end

    test "WH-36 (4): an endpoint that opted out is warned but never disabled" do
      {row, []} = failing([0, 6, 13, 24, 48, 71], false)
      {warned, [:warn]} = fail(row, 72, false)
      {_row, []} = fail(warned, 200, false)
    end

    test "WH-36 (2), WH-23: a 410 asks for the disable at once" do
      gone = %Outcome{result: :failed_permanent, reason: :gone, status: 410, endpoint: :disable}
      params = Settings.health()
      assert {_row, [:disable_gone]} = Health.record(@row, gone, :allow, true, hours(0), params)
    end
  end

  describe "WH-35 WH-55 breaker" do
    test "WH-35, WH-55: five failures in a row open the breaker for 30 seconds and a successful probe closes it" do
      down = %{@failure | breaker: :failure}
      params = Settings.health()

      {row, effects} =
        Enum.reduce(1..5, {@row, []}, fn _n, {row, _effects} ->
          Health.record(row, down, :allow, true, @start, params)
        end)

      assert effects == [:breaker_opened]
      assert row["breaker_state"] == "open"
      assert DateTime.diff(row["breaker_retry_at"], @start, :second) == 30
      assert {{:reject, 30_000}, nil} = Health.admit(row, @start, params)

      later = DateTime.add(@start, 31, :second)
      assert {:probe, probing} = Health.admit(row, later, params)
      assert probing["breaker_state"] == "half_open"
      assert {{:reject, _wait}, nil} = Health.admit(probing, later, params)

      up = %{@success | breaker: :success}
      assert {closed, [:breaker_closed]} = Health.record(probing, up, :probe, true, later, params)
      assert closed["breaker_state"] == "closed"
      assert closed["breaker_retry_at"] == nil
      assert closed["breaker_trips"] == 0
    end
  end

  describe "WH-23 reason codes" do
    test "WH-23: an outcome's reason code names the status class or the failure" do
      assert Health.code(@failure) == "http_5xx"
      assert Health.code(%Outcome{result: :retry, reason: :timeout}) == "timeout"
      refused = %Outcome{result: :retry, reason: :connection_error}
      assert Health.code(refused) == "connection_failed"

      assert Health.code(%Outcome{result: :failed_permanent, reason: :redirect_not_followed}) ==
               "redirect_not_followed"
    end
  end
end
