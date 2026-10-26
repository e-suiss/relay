defmodule Relay.Clock.VirtualClockTest do
  use Relay.SqlCase, async: true

  import Relay.Golden
  import RelayTest.WaitpointFixture

  @day 86_400_000

  setup do
    %{s: setup!()}
  end

  defp advance(ms),
    do:
      row("SELECT * FROM relay_fn.virtual_clock_advance($1, $2, $3, $4, $5, $6)", [
        ms,
        digest() | actor()
      ])

  defp offset_now,
    do: one("SELECT (extract(epoch FROM relay_private.business_now() - now()) * 1000)::bigint")

  describe "TN-8 X-27 the virtual clock exists only in test" do
    test "X-27: a live context cannot advance or read a virtual clock", ctx do
      "active" = ctx(ctx.s.tenant, "live")

      assert ["not_test_environment", nil, nil] = advance(60_000)

      assert ["not_test_environment", nil, nil] =
               row("SELECT * FROM relay_fn.virtual_clock_get()")

      assert offset_now() == 0
      assert one("SELECT count(*) FROM relay.virtual_clocks") == 0
    end

    test "TN-8: steps accumulate and move business time of the test environment", ctx do
      assert ["ok", 0, _] = row("SELECT * FROM relay_fn.virtual_clock_get()")
      assert ["advanced", 60_000, _] = advance(60_000)
      assert ["advanced", 120_000, at] = advance(60_000)
      assert offset_now() == 120_000
      assert ["ok", 120_000, ^at] = row("SELECT * FROM relay_fn.virtual_clock_get()")

      "active" = ctx(ctx.s.tenant, "live")
      assert offset_now() == 0
    end

    test "TN-8: a step is at most 366 days and the offset at most ten years" do
      for step <- [0, -1, 366 * @day + 1, nil] do
        assert ["invalid_step", _, nil] = advance(step)
      end

      for _ <- 1..9, do: ["advanced", _, _] = advance(366 * @day)
      assert ["invalid_step", offset, nil] = advance(366 * @day)
      assert offset == 9 * 366 * @day
      assert ["advanced", 315_360_000_000, _] = advance(3_650 * @day - offset)
      assert ["invalid_step", _, nil] = advance(1)
    end

    test "X-27: the database refuses a live clock row and every step is audited" do
      as_owner(fn -> %{s: setup!()} end, fn ctx ->
        ["advanced", _, _] = advance(1_000)

        assert one(
                 "SELECT count(*) FROM relay.audit_log WHERE action = 'virtual_clock.advanced' AND tenant_id = $1",
                 [ctx.s.tenant]
               ) == 1

        "active" = ctx(ctx.s.tenant, "live")

        assert sql_error(
                 "INSERT INTO relay.virtual_clocks (tenant_id, environment, offset_ms, version, updated_at, updated_by_ref) VALUES ($1, 'live', 0, 1, now(), 'x')",
                 [ctx.s.tenant]
               ).postgres.constraint == "virtual_clocks_environment_check"
      end)
    end

    test "TN-8: business time is the database clock plus the test offset and nothing else" do
      assert_golden(
        "business_now.sql",
        one(
          "SELECT p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'relay_private' AND p.proname = 'business_now'"
        )
      )
    end
  end
end
