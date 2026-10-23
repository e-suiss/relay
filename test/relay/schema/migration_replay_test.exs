defmodule Relay.Schema.MigrationReplayTest do
  use ExUnit.Case, async: false

  @moduletag :nightly
  @moduletag timeout: 1_800_000

  @database "relay_replay"
  @replayed 2
  @tenants 12
  @seed 20_261_023

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

  defp connect(login) do
    {:ok, conn} =
      login
      |> RelayDev.Database.connection()
      |> Keyword.put(:database, @database)
      |> Postgrex.start_link()

    conn
  end

  defp q!(conn, sql, params \\ []), do: Postgrex.query!(conn, sql, params).rows

  defp scoped(conn, tenant, environment, fun) do
    {:ok, result} =
      Postgrex.transaction(
        conn,
        fn tx ->
          q!(tx, "SELECT relay_fn.ctx_set($1, $2)", [tenant, environment])
          fun.(tx)
        end,
        timeout: :infinity
      )

    result
  end

  defp bytes(n), do: :rand.bytes(n)

  defp id, do: Relay.Id.build(System.os_time(:millisecond), bytes(10))

  defp actor, do: ["system", "relay:replay", "relay", nil]

  defp seed(conn) do
    :rand.seed(:exsss, {@seed, @seed, @seed})
    [[region]] = q!(conn, "SELECT region FROM relay.installation")

    for t <- 1..@tenants do
      tenant = id()

      [["created", ^tenant]] =
        q!(
          conn,
          "SELECT result, tenant_id FROM relay_ops.tenant_create($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)",
          [
            tenant,
            "acc-replay-#{t}",
            region,
            "general",
            "Europe/Istanbul",
            "tr",
            bytes(32) | actor()
          ]
        )

      for environment <- ["live", "test"] do
        scoped(conn, tenant, environment, &seed_scope(&1, t))
      end
    end
  end

  defp seed_scope(tx, t) do
    wrap = key!(tx, "dek_wrap")
    _data = key!(tx, "data")
    bidx = id()

    [["created"]] =
      q!(
        tx,
        "SELECT relay_fn.blind_index_key_register($1, $2, $3, $4, $5, $6, $7)",
        [bidx, "pkcs11:object=bidx", bytes(32) | actor()]
      )

    for r <- 1..(5 + rem(t * 7, 40)) do
      recipient = id()

      [["created", ^recipient]] =
        q!(
          tx,
          "SELECT result, recipient_id FROM relay_fn.recipient_create($1, $2, $3, $4, $5, $6, $7, $8)",
          [recipient, "subscriber", bytes(32), bidx, bytes(48), id(), bytes(32), wrap]
        )

      for n <- 1..(1 + rem(r, 4)), do: seed_notification(tx, recipient, "#{t}-#{r}", n)
    end

    [["appended"]] =
      q!(
        tx,
        "SELECT relay_fn.audit_append($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)",
        [id(), "replay.seeded" | actor()] ++ [nil, nil, nil, nil, nil, bytes(32)]
      )
  end

  defp seed_notification(tx, recipient, stream, n) do
    notification = id()

    [["created", ^notification]] =
      q!(
        tx,
        "SELECT result, notification_id FROM relay_fn.notification_accept($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)",
        [notification, recipient, nil, "replay-#{stream}-#{n}", "transactional"] ++
          [nil, "system", nil, nil, nil, false, nil]
      )

    for {channel, provider} <- Enum.take([{"email", nil}, {"sms", "acme_sms"}], 1 + rem(n, 2)) do
      [["opened", _]] =
        q!(
          tx,
          "SELECT result, delivery_id FROM relay_fn.delivery_open($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)",
          [id(), notification, channel, "address", nil, bytes(32), provider] ++
            [nil, nil, "send", nil, nil, nil, nil]
        )
    end

    [["appended" | _]] =
      q!(
        tx,
        "SELECT * FROM relay_fn.outbox_append($1, $2, $3, $4, $5)",
        [id(), "notification.accepted", "notification:replay-#{stream}", %{"n" => n}, nil]
      )
  end

  defp key!(tx, purpose) do
    key = id()

    [["created"]] =
      q!(
        tx,
        "SELECT relay_fn.tenant_key_register($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
        [key, purpose, nil, "pkcs11:object=kek;v=1", bytes(61), bytes(32) | actor()]
      )

    key
  end

  defp counts(conn) do
    for table <- ~w(tenants recipients notifications deliveries outbox_events audit_log),
        into: %{},
        do: {table, q!(conn, "SELECT count(*) FROM relay.#{table}") |> hd() |> hd()}
  end

  test "OP-57: the newest migrations replay over production-shaped data and leave the schema sound" do
    {:ok, _} = Application.ensure_all_started(:postgrex)
    all = versions()
    {base, replayed} = Enum.split(all, length(all) - @replayed)

    :ok = RelayDev.Database.create(@database)
    assert RelayDev.Database.upgrade(@database, List.last(base)) == base

    worker = connect("relay_worker")
    seed(worker)
    admin = connect(:admin)
    before = counts(admin)
    assert before["notifications"] > 1_000

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
           WHERE n.nspname LIKE 'relay%' AND NOT k.convalidated
           """) == []

    assert q!(admin, """
           SELECT n.nspname || '.' || p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'relay_ops' AND p.proowner <> 'relay_maint'::regrole
           """) == []

    violations =
      q!(admin, "SELECT * FROM relay_ops.orphan_check()") ++
        q!(admin, "SELECT * FROM relay_ops.reference_check()")

    assert Enum.filter(violations, fn [_check, _table, n] -> n > 0 end) == []

    GenServer.stop(worker)
    GenServer.stop(admin)
  end
end
