defmodule Relay.Tenancy.KillSwitchRaceTest do
  use Relay.SqlCase, async: false

  @moduletag :real_engine

  @rounds 40
  @engage "SELECT kill_switch_id FROM relay_fn.kill_switch_engage($1, 'tenant', NULL, 'sms', 'all', NULL, NULL, NULL, 'off', NULL, NULL, 'race', NULL, now() + interval '1 hour', NULL, 'operator', $2, $3, $4, $5, $6)"

  defp in_tx(conn, tenant, sql, params) do
    Postgrex.query!(conn, "BEGIN", [])
    Postgrex.query!(conn, "SELECT relay_fn.ctx_set($1, 'test')", [tenant])
    %{rows: [row]} = Postgrex.query!(conn, sql, params)
    Postgrex.query!(conn, "COMMIT", [])
    row
  end

  setup do
    setup_conn = connect("relay_worker")
    s = committed(setup_conn, &scenario!/0)

    ksw =
      committed(setup_conn, fn ->
        "active" = ctx(s.tenant)
        one(@engage, [id(), digest() | actor()])
      end)

    %{s: s, ksw: ksw, conn: setup_conn}
  end

  test "TN-40: the sweep and a job start racing on one delivery never lose it and never open it after the pause",
       %{s: s, ksw: ksw, conn: conn} do
    sweeper = connect("relay_worker")
    starter = connect("relay_worker")

    for _ <- 1..@rounds do
      delivery =
        committed(conn, fn ->
          "active" = ctx(s.tenant)
          delivery!(s.notification)
        end)

      sweep =
        Task.async(fn ->
          in_tx(sweeper, s.tenant, "SELECT * FROM relay_fn.deliveries_pause_matching($1, 500)", [
            ksw
          ])
        end)

      start =
        Task.async(fn ->
          in_tx(
            starter,
            s.tenant,
            "SELECT result FROM relay_fn.attempt_open($1, $2, 'acme_sms', NULL, $3)",
            [id(), delivery, "pik-" <> Base.encode16(id())]
          )
        end)

      [paused, _more] = Task.await(sweep, 10_000)
      [opened] = Task.await(start, 10_000)

      [[paused_at?, failure_kind, attempts]] =
        committed(conn, fn ->
          "active" = ctx(s.tenant)

          rows(
            "SELECT d.paused_at IS NOT NULL, d.failure_kind, (SELECT count(*)::int FROM relay.delivery_attempts a WHERE a.delivery_id = d.id) FROM relay.deliveries d WHERE d.id = $1",
            [delivery]
          )
        end)

      assert failure_kind == nil
      assert paused in [0, 1]
      assert paused_at?

      case opened do
        "delivery_paused" -> assert attempts == 0
        "opened" -> assert attempts == 1
      end
    end
  end
end
