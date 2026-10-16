defmodule Relay.Sql.OutboxTest do
  use Relay.SqlCase, async: true

  alias Relay.Repo

  @append "SELECT * FROM relay_fn.outbox_append($1, $2, $3, $4, NULL)"
  @usage "SELECT relay_fn.usage_record_append($1, $2, 'sms', 'acme', 'TR', NULL, NULL, $3, $4, $5, $6, $7, $8, $9)"

  defp append(stream, payload \\ %{"id" => "x"}),
    do: row(@append, [id(), "notification.accepted", stream, payload])

  test "C-71: stream sequence numbers are gapless per stream" do
    tenant = tenant!()
    ctx(tenant)

    assert rows("SELECT * FROM relay_fn.stream_next_seq('inbox:r1')") == [[1, 1]]
    assert rows("SELECT * FROM relay_fn.stream_next_seq('inbox:r1')") == [[1, 2]]
    assert rows("SELECT * FROM relay_fn.stream_next_seq('inbox:r2')") == [[1, 1]]

    assert error_message("SELECT * FROM relay_fn.stream_next_seq('Bad Key')") ==
             "invalid_argument"

    {:error, :rolled_back} =
      Repo.transaction(fn ->
        [[1, 3]] = rows("SELECT * FROM relay_fn.stream_next_seq('inbox:r1')")
        Repo.rollback(:rolled_back)
      end)

    assert rows("SELECT * FROM relay_fn.stream_next_seq('inbox:r1')") == [[1, 3]]
  end

  test "INV-2: outbox rows are appended with their stream sequence, claimed in order and dispatched once" do
    tenant = tenant!()
    ctx(tenant)

    assert ["appended", 1, 1] = append("notification:a")
    assert ["appended", 1, 2] = append("notification:a")
    assert ["appended", 1, 1] = append("notification:b")

    claimed = rows("SELECT id, seq, stream_key FROM relay_fn.outbox_claim(10)")
    ids = Enum.map(claimed, &hd/1)

    assert Enum.sort(Enum.map(claimed, &tl/1)) ==
             [[1, "notification:a"], [1, "notification:b"], [2, "notification:a"]]

    assert ids == Enum.sort(ids)

    [first | _] = ids
    missing = id()

    assert rows("SELECT * FROM relay_fn.outbox_mark_dispatched($1)", [[first, missing]])
           |> Enum.sort() ==
             Enum.sort([[first, "dispatched"], [missing, "not_found"]])

    assert rows("SELECT * FROM relay_fn.outbox_mark_dispatched($1)", [[first]]) == [
             [first, "already_dispatched"]
           ]

    assert length(rows("SELECT id FROM relay_fn.outbox_claim(10)")) == 2
  end

  test "OP-5: concurrent claimers skip rows another transaction holds" do
    opts = Keyword.drop(Repo.config(), [:pool, :pool_size, :ownership_timeout])
    {:ok, a} = Postgrex.start_link(opts)
    {:ok, b} = Postgrex.start_link(opts)
    tenant = id()

    setup = fn conn ->
      Postgrex.query!(conn, "SET LOCAL ROLE relay_api", [])

      %{rows: [["created", ^tenant]]} =
        Postgrex.query!(
          conn,
          "SELECT * FROM relay_ops.tenant_create($1, $2, (SELECT region FROM relay.installation), 'general', 'Europe/Istanbul', 'tr', $3, $4, $5, $6, $7)",
          [tenant, "acc_" <> Base.encode16(tenant), digest() | actor()]
        )

      Postgrex.query!(conn, "SELECT relay_fn.ctx_set($1, 'test')", [tenant])

      for _ <- 1..2,
          do:
            Postgrex.query!(conn, @append, [id(), "notification.accepted", "notification:c", %{}])
    end

    {:ok, _} = Postgrex.transaction(a, setup)

    claim = fn conn ->
      Postgrex.query!(conn, "BEGIN", [])
      Postgrex.query!(conn, "SET LOCAL ROLE relay_api", [])
      Postgrex.query!(conn, "SELECT relay_fn.ctx_set($1, 'test')", [tenant])
      Postgrex.query!(conn, "SELECT seq FROM relay_fn.outbox_claim(1)", []).rows
    end

    assert Enum.sort(claim.(a) ++ claim.(b)) == [[1], [2]]
    Postgrex.query!(a, "ROLLBACK", [])
    Postgrex.query!(b, "ROLLBACK", [])
  end

  test "C-88: usage rows are written once per closed UTC day, repeats are duplicates and different counts conflict" do
    yesterday = Date.add(Date.utc_today(), -1)
    month = Date.beginning_of_month(yesterday)
    Repo.query!("SET LOCAL TimeZone = 'UTC'")

    Repo.query!(
      "SELECT relay_private.partition_create('usage_records', $1::date::timestamptz, ($1::date + interval '1 month')::timestamptz)",
      [month]
    )

    tenant = tenant!()
    ctx(tenant)

    record = fn day, outcome, test?, quantity ->
      one(@usage, [id(), day, outcome, test?, quantity, 1, 1, 1000, "TRY"])
    end

    assert record.(Date.utc_today(), "accepted", false, 3) == "day_open"
    assert record.(yesterday, "accepted", false, 3) == "recorded"
    assert record.(yesterday, "accepted", false, 3) == "duplicate"
    assert record.(yesterday, "accepted", false, 4) == "conflict"
    assert record.(yesterday, "accepted", true, 1) == "recorded"

    assert rows(
             "SELECT is_test, quantity FROM relay.usage_records WHERE usage_day = $1 ORDER BY is_test",
             [yesterday]
           ) == [[false, 3], [true, 1]]

    assert error_message("UPDATE relay.usage_records SET quantity = 9") =~ "permission denied"
  end
end
