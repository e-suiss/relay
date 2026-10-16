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

  test "OP-68: the idempotency scope is tenant, environment, endpoint and key" do
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

  defp committed_tenant(conn) do
    committed(conn, fn ->
      tenant = tenant!()
      ctx(tenant)
      {tenant, tenant_key!("data")}
    end)
  end

  test "C-79: the lookup covers the last 24 hours across the day boundary and nothing older" do
    {tenant, data_key} = committed_tenant(connect("relay_worker"))

    committed(connect("relay_maint"), fn ->
      rows("SET LOCAL TimeZone = 'UTC'")

      for hours <- [23, 25] do
        rows(
          "SELECT relay_private.partition_create('idempotency_keys', date_trunc('day', now() - make_interval(hours => $1)), date_trunc('day', now() - make_interval(hours => $1)) + interval '1 day')",
          [hours]
        )
      end
    end)

    recent = key()
    old = key()

    committed(connect(:admin), fn ->
      for {key, hours} <- [{recent, 23}, {old, 25}] do
        rows(
          """
          INSERT INTO relay.idempotency_keys (tenant_id, environment, id, created_at, endpoint, key,
            request_fingerprint, expires_at, response_status, response_headers, response_body_ct,
            response_body_key_id)
          SELECT $1, 'test', uuidv7(), t, $2, $3, $4, t + interval '24 hours', 200, '{}', $5, $6
          FROM (SELECT now() - make_interval(hours => $7) AS t) s
          """,
          [tenant, @endpoint, key, digest(), digest(), data_key, hours]
        )
      end
    end)

    ctx(tenant)
    assert hd(row(@begin, [@endpoint, recent, digest()])) == "conflict"
    assert hd(row(@begin, [@endpoint, old, digest()])) == "created"
  end

  describe "concurrent requests" do
    setup do
      a = connect("relay_api")
      b = connect("relay_api")
      {tenant, data_key} = committed_tenant(a)
      %{a: a, b: b, tenant: tenant, data_key: data_key}
    end

    defp open(conn, tenant) do
      on(conn, fn ->
        rows("BEGIN")
        ctx(tenant)
      end)
    end

    defp begin_on(conn, key, fingerprint) do
      on(conn, fn -> hd(row(@begin, [@endpoint, key, fingerprint])) end)
    end

    test "API-15: two concurrent claims of one key produce exactly one created", c do
      key = key()
      fingerprint = digest()
      open(c.a, c.tenant)
      open(c.b, c.tenant)

      assert begin_on(c.a, key, fingerprint) == "created"
      assert begin_on(c.b, key, fingerprint) == "in_progress"

      on(c.a, fn ->
        "stored" = one(@complete, [@endpoint, key, fingerprint, 201, %{}, digest(), c.data_key])
        rows("COMMIT")
      end)

      assert begin_on(c.b, key, fingerprint) == "replayed"
      on(c.b, fn -> rows("ROLLBACK") end)
    end

    test "API-13: a concurrent request with a different body still waits as in_progress", c do
      key = key()
      open(c.a, c.tenant)
      open(c.b, c.tenant)

      assert begin_on(c.a, key, digest()) == "created"
      assert begin_on(c.b, key, digest()) == "in_progress"

      on(c.a, fn -> rows("ROLLBACK") end)
      assert begin_on(c.b, key, digest()) == "created"
      on(c.b, fn -> rows("ROLLBACK") end)
    end
  end
end
