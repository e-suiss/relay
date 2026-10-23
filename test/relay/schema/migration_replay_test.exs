defmodule Relay.Schema.MigrationReplayTest do
  use ExUnit.Case, async: false

  @moduletag :nightly
  @moduletag timeout: 2_700_000

  @database "relay_replay"
  @seed_after 20_261_017_100_900
  @default_deliveries 1_000_000
  @tenants 20
  @recipients 500
  @workers 4
  @infinity [timeout: :infinity]

  defp versions do
    "priv/repo/migrations"
    |> File.ls!()
    |> Enum.map(&Integer.parse/1)
    |> Enum.flat_map(fn
      {version, "_" <> _} -> [version]
      _ -> []
    end)
    |> Enum.sort()
  end

  defp deliveries do
    case System.get_env("RELAY_REPLAY_DELIVERIES") do
      nil -> @default_deliveries
      "" -> @default_deliveries
      value -> String.to_integer(value)
    end
  end

  defp connect do
    {:ok, conn} =
      :admin
      |> RelayDev.Database.connection()
      |> Keyword.put(:database, @database)
      |> Postgrex.start_link()

    conn
  end

  defp q!(conn, sql, params \\ []), do: Postgrex.query!(conn, sql, params, @infinity).rows

  defp scoped(conn, {tenant, environment}, fun) do
    {:ok, result} =
      Postgrex.transaction(
        conn,
        fn tx ->
          q!(tx, "SELECT relay_fn.ctx_set($1, $2)", [tenant, environment])
          fun.(tx)
        end,
        @infinity
      )

    result
  end

  defp id, do: Relay.Id.build(System.os_time(:millisecond), :crypto.strong_rand_bytes(10))

  defp digest, do: :crypto.strong_rand_bytes(32)

  defp actor, do: ["system", "relay:replay", "relay", nil]

  defp tenants(conn) do
    [[region]] = q!(conn, "SELECT region FROM relay.installation")

    for t <- 1..@tenants do
      tenant = id()

      [["created", ^tenant]] =
        q!(
          conn,
          "SELECT result, tenant_id FROM relay_ops.tenant_create($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)",
          [tenant, "acc-replay-#{t}", region, "general", "Europe/Istanbul", "tr", digest()] ++
            actor()
        )

      tenant
    end
  end

  defp seed(scopes, per_scope) do
    scopes
    |> Task.async_stream(
      fn scope ->
        conn = connect()

        try do
          seed_scope(conn, scope, per_scope)
        after
          GenServer.stop(conn)
        end
      end,
      max_concurrency: @workers,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.each(fn {:ok, :ok} -> :ok end)
  end

  defp seed_scope(conn, scope, notifications) do
    {wrap, bidx} = scoped(conn, scope, &keys/1)

    [[@recipients]] =
      scoped(conn, scope, fn tx ->
        q!(
          tx,
          """
          SELECT count(*) FROM generate_series(1, $1::int) g
          CROSS JOIN LATERAL relay_fn.recipient_create(uuidv7(), 'subscriber',
            sha256(convert_to('replay:' || g, 'UTF8')), $2, sha256(convert_to('ct:' || g, 'UTF8')),
            uuidv7(), sha256(convert_to('dek:' || g, 'UTF8')), $3) r
          WHERE r.result = 'created'
          """,
          [@recipients, bidx, wrap]
        )
      end)

    [[^notifications]] =
      scoped(conn, scope, fn tx ->
        q!(
          tx,
          """
          SELECT count(*) FROM (SELECT r.id, row_number() OVER (ORDER BY r.id) AS no FROM relay.recipients r
            WHERE r.tenant_id = $1 AND r.environment = $2) r
          JOIN generate_series(1, $3::int) g ON g % $4::int = r.no - 1
          CROSS JOIN LATERAL relay_fn.notification_accept(uuidv7(), r.id, NULL, 'replay:' || g,
            'transactional', NULL, 'system', NULL, NULL, NULL, false, NULL) n
          WHERE n.result = 'created'
          """,
          Tuple.to_list(scope) ++ [notifications, @recipients]
        )
      end)

    [[opened]] =
      scoped(conn, scope, fn tx ->
        q!(
          tx,
          """
          SELECT count(*) FROM relay.notifications n
          CROSS JOIN LATERAL unnest(ARRAY['email', 'sms']) c
          CROSS JOIN LATERAL relay_fn.delivery_open(uuidv7(), n.id, c, 'address', NULL,
            sha256(convert_to(n.id::text || c, 'UTF8')), CASE c WHEN 'sms' THEN 'acme_sms' END,
            NULL, NULL, 'send', NULL, NULL, NULL, NULL) d
          WHERE n.tenant_id = $1 AND n.environment = $2 AND d.result = 'opened'
          """,
          Tuple.to_list(scope)
        )
      end)

    true = opened == 2 * notifications

    scoped(conn, scope, fn tx ->
      q!(
        tx,
        """
        SELECT count(*) FROM relay.notifications n
        CROSS JOIN LATERAL relay_fn.outbox_append(uuidv7(), 'notification.accepted',
          'recipient:' || n.recipient_id, jsonb_build_object('notification', n.id), NULL) o
        WHERE n.tenant_id = $1 AND n.environment = $2 AND o.result = 'appended'
        """,
        Tuple.to_list(scope)
      )

      q!(
        tx,
        """
        SELECT count(*) FROM relay.deliveries d
        CROSS JOIN LATERAL relay_fn.ledger_append(uuidv7(), d.id, NULL, 'provider_api',
          'provider.accepted', NULL, d.provider, NULL, now(), NULL, 1::smallint, NULL, NULL, NULL,
          NULL, NULL, NULL) l
        WHERE d.tenant_id = $1 AND d.environment = $2 AND get_byte(d.target_key, 0) % 4 = 0
        """,
        Tuple.to_list(scope)
      )

      [["appended"]] =
        q!(
          tx,
          "SELECT relay_fn.audit_append($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)",
          [id(), "replay.seeded" | actor()] ++ [nil, nil, nil, nil, nil, digest()]
        )
    end)

    :ok
  end

  defp keys(tx) do
    register = "SELECT relay_fn.tenant_key_register($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)"
    wrap = id()
    [["created"]] = q!(tx, register, [wrap, "dek_wrap", nil, "pkcs11:object=kek;v=1"] ++ blob())
    [["created"]] = q!(tx, register, [id(), "data", nil, "pkcs11:object=kek;v=1"] ++ blob())
    bidx = id()

    [["created"]] =
      q!(
        tx,
        "SELECT relay_fn.blind_index_key_register($1, $2, $3, $4, $5, $6, $7)",
        [bidx, "pkcs11:object=bidx", digest() | actor()]
      )

    {wrap, bidx}
  end

  defp blob, do: [:crypto.strong_rand_bytes(61), digest() | actor()]

  defp counts(conn) do
    for table <-
          ~w(tenants recipients notifications deliveries delivery_events outbox_events audit_log),
        into: %{},
        do: {table, q!(conn, "SELECT count(*) FROM relay.#{table}") |> hd() |> hd()}
  end

  test "OP-71: every migration replays from scratch over about a million synthetic deliveries and leaves the schema sound" do
    {:ok, _} = Application.ensure_all_started(:postgrex)
    all = versions()
    assert @seed_after in all
    {base, replayed} = Enum.split_with(all, &(&1 <= @seed_after))
    assert replayed != []

    :ok = RelayDev.Database.create(@database)
    assert RelayDev.Database.upgrade(@database, @seed_after) == base

    admin = connect()

    scopes =
      for tenant <- tenants(admin), environment <- ["live", "test"], do: {tenant, environment}

    per_scope = div(deliveries(), 2 * length(scopes))
    seed(scopes, per_scope)
    before = counts(admin)
    assert before["deliveries"] == per_scope * 2 * length(scopes)
    assert before["deliveries"] >= deliveries() * 0.99

    {micros, applied} = :timer.tc(fn -> RelayDev.Database.upgrade(@database, :all) end)
    assert applied == replayed
    assert micros < 600_000_000

    assert counts(admin) == before

    assert q!(admin, """
           SELECT c.relname::text FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
           JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname LIKE 'relay%' AND (NOT x.indisvalid OR NOT x.indisready)
           """) == []

    assert q!(admin, """
           SELECT k.conname::text FROM pg_constraint k JOIN pg_namespace n ON n.oid = k.connamespace
           WHERE n.nspname = 'relay' AND NOT k.convalidated
           """) == []

    assert q!(admin, """
           SELECT n.nspname || '.' || p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'relay_ops' AND p.proowner <> 'relay_maint'::regrole
           """) == []

    violations =
      q!(admin, "SELECT * FROM relay_ops.orphan_check()") ++
        q!(admin, "SELECT * FROM relay_ops.reference_check()")

    assert Enum.filter(violations, fn [_check, _table, n] -> n > 0 end) == []

    GenServer.stop(admin)
  end
end
