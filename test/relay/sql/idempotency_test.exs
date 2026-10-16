defmodule Relay.Sql.IdempotencyTest do
  use Relay.SqlCase, async: false

  alias Relay.Repo

  @begin "SELECT * FROM relay_fn.idempotency_begin($1, $2, $3)"
  @complete "SELECT relay_fn.idempotency_complete($1, $2, $3, $4, $5, $6, $7)"
  @endpoint "POST /v1/events"

  defp key, do: "key_" <> Base.encode16(:crypto.strong_rand_bytes(8))

  defp setup_tenant do
    tenant = tenant!()
    ctx(tenant)
    {tenant, tenant_key!("data")}
  end

  test "API-11: keys shorter than 8 or longer than 255 characters are rejected" do
    setup_tenant()

    for bad <- [String.duplicate("k", 7), String.duplicate("k", 256)] do
      assert error_message(@begin, [@endpoint, bad, digest()]) == "invalid_argument"
    end

    assert hd(row(@begin, [@endpoint, String.duplicate("k", 8), digest()])) == "created"
    assert hd(row(@begin, [@endpoint, String.duplicate("k", 255), digest()])) == "created"
  end

  test "OP-6: a stored response replays byte for byte and a different body conflicts" do
    {_tenant, data_key} = setup_tenant()
    key = key()
    body = digest()
    fingerprint = digest()

    assert row(@begin, [@endpoint, key, fingerprint]) == ["created", nil, nil, nil, nil]

    assert one(@complete, [
             @endpoint,
             key,
             fingerprint,
             202,
             %{"location" => "/v1/x"},
             body,
             data_key
           ]) ==
             "stored"

    assert row(@begin, [@endpoint, key, fingerprint]) ==
             ["replayed", 202, %{"location" => "/v1/x"}, body, data_key]

    assert row(@begin, [@endpoint, key, digest()]) == ["conflict", nil, nil, nil, nil]
  end

  test "API-11: the scope is tenant, environment, endpoint and key" do
    {tenant, data_key} = setup_tenant()
    key = key()
    fingerprint = digest()

    ["created" | _] = row(@begin, [@endpoint, key, fingerprint])
    "stored" = one(@complete, [@endpoint, key, fingerprint, 201, %{}, digest(), data_key])

    assert hd(row(@begin, ["POST /v1/notifications", key, fingerprint])) == "created"

    ctx(tenant, "live")
    assert hd(row(@begin, [@endpoint, key, fingerprint])) == "created"

    ctx(tenant!())
    assert hd(row(@begin, [@endpoint, key, fingerprint])) == "created"
  end

  test "API-14: 400, 401, 403 and 429 responses are not stored" do
    {_tenant, data_key} = setup_tenant()

    for status <- [400, 401, 403, 429] do
      key = key()
      fingerprint = digest()
      ["created" | _] = row(@begin, [@endpoint, key, fingerprint])

      assert one(@complete, [@endpoint, key, fingerprint, status, %{}, digest(), data_key]) ==
               "not_cacheable"

      assert hd(row(@begin, [@endpoint, key, fingerprint])) == "created"
    end
  end

  test "API-14: completing without a claim in the transaction stores nothing" do
    {_tenant, data_key} = setup_tenant()
    key = key()
    fingerprint = digest()

    assert one(@complete, [@endpoint, key, fingerprint, 200, %{}, digest(), data_key]) ==
             "not_claimed"

    ["created" | _] = row(@begin, [@endpoint, key, fingerprint])
    "stored" = one(@complete, [@endpoint, key, fingerprint, 200, %{}, digest(), data_key])

    assert one(@complete, [@endpoint, key, fingerprint, 200, %{}, digest(), data_key]) ==
             "not_claimed"
  end

  test "API-14: a rolled back transaction leaves no idempotency record" do
    {_tenant, data_key} = setup_tenant()
    key = key()
    fingerprint = digest()

    {:error, :injected} =
      Repo.transaction(fn ->
        ["created" | _] = row(@begin, [@endpoint, key, fingerprint])
        "stored" = one(@complete, [@endpoint, key, fingerprint, 200, %{}, digest(), data_key])
        Repo.rollback(:injected)
      end)

    assert hd(row(@begin, [@endpoint, key, fingerprint])) == "created"
  end

  test "C-79: the lookup covers the last 24 hours across the day boundary and nothing older" do
    {tenant, data_key} = setup_tenant()
    reset_role()
    Repo.query!("SET LOCAL TimeZone = 'UTC'")

    for hours <- [23, 25] do
      Repo.query!(
        "SELECT relay_private.partition_create('idempotency_keys', date_trunc('day', now() - make_interval(hours => $1)), date_trunc('day', now() - make_interval(hours => $1)) + interval '1 day')",
        [hours]
      )
    end

    insert = fn key, fingerprint, hours ->
      Repo.query!(
        """
        INSERT INTO relay.idempotency_keys (tenant_id, environment, id, created_at, endpoint, key,
          request_fingerprint, expires_at, response_status, response_headers, response_body_ct,
          response_body_key_id)
        SELECT $1, 'test', uuidv7(), t, $2, $3, $4, t + interval '24 hours', 200, '{}', $5, $6
        FROM (SELECT now() - make_interval(hours => $7) AS t) s
        """,
        [tenant, @endpoint, key, fingerprint, digest(), data_key, hours]
      )
    end

    recent = key()
    old = key()
    insert.(recent, digest(), 23)
    insert.(old, digest(), 25)
    as_role("relay_api")

    assert hd(row(@begin, [@endpoint, recent, digest()])) == "conflict"
    assert hd(row(@begin, [@endpoint, old, digest()])) == "created"
  end

  describe "concurrent requests" do
    setup do
      opts = Keyword.drop(Repo.config(), [:pool, :pool_size, :ownership_timeout])
      {:ok, a} = Postgrex.start_link(opts)
      {:ok, b} = Postgrex.start_link(opts)

      {:ok, {tenant, data_key}} =
        Postgrex.transaction(a, fn conn ->
          Postgrex.query!(conn, "SET LOCAL ROLE relay_api", [])
          tenant = id()

          %{rows: [["created", ^tenant]]} =
            Postgrex.query!(
              conn,
              "SELECT * FROM relay_ops.tenant_create($1, $2, (SELECT region FROM relay.installation), 'general', 'Europe/Istanbul', 'tr', $3, $4, $5, $6, $7)",
              [tenant, "acc_" <> Base.encode16(tenant), digest() | actor()]
            )

          Postgrex.query!(conn, "SELECT relay_fn.ctx_set($1, 'test')", [tenant])
          data_key = id()

          %{rows: [["created"]]} =
            Postgrex.query!(
              conn,
              "SELECT relay_fn.tenant_key_register($1, 'data', NULL, 'pkcs11:token=relay;object=kek', $2, $3, $4, $5, $6, $7)",
              [data_key, digest(), digest() | actor()]
            )

          {tenant, data_key}
        end)

      %{a: a, b: b, tenant: tenant, data_key: data_key}
    end

    defp open(conn, tenant) do
      Postgrex.query!(conn, "BEGIN", [])
      Postgrex.query!(conn, "SET LOCAL ROLE relay_api", [])
      Postgrex.query!(conn, "SELECT relay_fn.ctx_set($1, 'test')", [tenant])
    end

    defp begin_on(conn, key, fingerprint) do
      %{rows: [[result | _]]} = Postgrex.query!(conn, @begin, [@endpoint, key, fingerprint])
      result
    end

    test "API-15: two concurrent claims of one key produce exactly one created", ctx do
      key = key()
      fingerprint = digest()
      open(ctx.a, ctx.tenant)
      open(ctx.b, ctx.tenant)

      assert begin_on(ctx.a, key, fingerprint) == "created"
      assert begin_on(ctx.b, key, fingerprint) == "in_progress"

      %{rows: [["stored"]]} =
        Postgrex.query!(ctx.a, @complete, [
          @endpoint,
          key,
          fingerprint,
          201,
          %{},
          digest(),
          ctx.data_key
        ])

      Postgrex.query!(ctx.a, "COMMIT", [])

      assert begin_on(ctx.b, key, fingerprint) == "replayed"
      Postgrex.query!(ctx.b, "ROLLBACK", [])
    end

    test "API-13: a concurrent request with a different body still waits as in_progress", ctx do
      key = key()
      open(ctx.a, ctx.tenant)
      open(ctx.b, ctx.tenant)

      assert begin_on(ctx.a, key, digest()) == "created"
      assert begin_on(ctx.b, key, digest()) == "in_progress"

      Postgrex.query!(ctx.a, "ROLLBACK", [])
      assert begin_on(ctx.b, key, digest()) == "created"
      Postgrex.query!(ctx.b, "ROLLBACK", [])
    end
  end
end
