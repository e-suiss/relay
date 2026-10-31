defmodule Relay.Repo.Migrations.CreateLaneCapacityFunction do
  use Ecto.Migration

  @functions [
    {"relay_ops.lane_capacity(integer)", "relay_maint", ~w(relay_api relay_worker)}
  ]

  # T-35 (2)
  # T-34 (1)
  # OP-8
  def up do
    execute("GRANT SELECT ON relay_queue.oban_jobs TO relay_maint")
    Enum.each(statements(), &execute/1)

    for {signature, owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
      if owner == "relay_owner", do: execute("ALTER FUNCTION #{signature} OWNER TO #{owner}")
    end
  end

  def down do
    for {signature, _owner, _grantees} <- Enum.reverse(@functions),
        do: execute("DROP FUNCTION #{signature}")

    execute("REVOKE SELECT ON relay_queue.oban_jobs FROM relay_maint")
  end

  defp statements do
    [
      ~S"""
      CREATE FUNCTION relay_ops.lane_capacity(p_window_s integer)
        RETURNS TABLE (lane text, queued bigint, completed bigint)
      LANGUAGE sql STABLE SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
      AS $fn$
        SELECT l.lane,
          (SELECT count(*) FROM relay_queue.oban_jobs j
            WHERE j.state = 'available'
              AND (j.queue = l.lane OR starts_with(j.queue, l.lane || '_')))
          + (SELECT count(*) FROM relay_queue.drr_waits w
            WHERE w.lane = l.lane::relay.lane AND w.state = 'waiting'
              AND w.scheduled_at <= now()),
          (SELECT count(*) FROM relay_queue.oban_jobs j
            WHERE j.state = 'completed'
              AND (j.queue = l.lane OR starts_with(j.queue, l.lane || '_'))
              AND j.completed_at > timezone('UTC', now())
                - make_interval(secs => least(greatest(coalesce(p_window_s, 60), 1), 3600)))
        FROM (VALUES ('l2'), ('l3')) AS l (lane)
        ORDER BY l.lane
      $fn$
      """
    ]
  end
end
