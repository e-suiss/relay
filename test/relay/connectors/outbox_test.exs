defmodule Relay.Connectors.OutboxTest do
  use Relay.DataCase, async: false

  alias Relay.Access.Clients
  alias Relay.Connectors.Connector
  alias Relay.Repo
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @database "relay_connector_source"

  defp admin(database) do
    config = Application.fetch_env!(:relay, Relay.Repo)

    {:ok, conn} =
      Postgrex.start_link(
        hostname: config[:hostname],
        port: config[:port],
        username: "relay",
        password: "relay",
        database: database
      )

    conn
  end

  defp source_database! do
    conn = admin("postgres")

    case Postgrex.query(conn, "CREATE DATABASE #{@database}", []) do
      {:ok, _result} -> :ok
      {:error, %Postgrex.Error{postgres: %{code: :duplicate_database}}} -> :ok
    end

    GenServer.stop(conn)
    admin(@database)
  end

  defp cloudevent(id, type) do
    %{
      "specversion" => "1.0",
      "id" => id,
      "source" => "https://shop.example.com/orders",
      "type" => type,
      "data" => %{
        "order" => "A-9",
        "customer" => %{"id" => "ce-" <> TenantFixture.random(), "email" => "c@example.com"}
      }
    }
  end

  defp events(scope) do
    {:ok, [[n]]} =
      Repo.in_scope(scope, fn _status ->
        Repo.scoped_query!("SELECT count(*) FROM relay.events", []).rows
      end)

    n
  end

  defp outcomes(conn, table, deadline) do
    %{rows: rows} =
      Postgrex.query!(conn, "SELECT id, relay_outcome FROM #{table} ORDER BY id", [])

    cond do
      Enum.all?(rows, fn [_id, outcome] -> outcome != nil end) ->
        rows

      System.monotonic_time(:millisecond) > deadline ->
        flunk("outbox rows were not relayed: #{inspect(rows)}")

      true ->
        Process.sleep(50)
        outcomes(conn, table, deadline)
    end
  end

  setup do
    :ok = Clients.reset()
    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    F.workflow!(tenant.live, token, "order-shipped")

    mapping = %{
      "type" => "com.shop.order.shipped",
      "workflow" => "order-shipped",
      "to_pointer" => "/customer",
      "data_fields" => ["/order"]
    }

    assert F.request(:post, "/v1/event_type_mappings", token, mapping).status == 201
    client = FakeAccess.client!(tenant.live, ["publish"])

    conn = source_database!()
    table = "outbox_" <> TenantFixture.random()

    Postgrex.query!(
      conn,
      """
      CREATE TABLE #{table} (
        id bigint PRIMARY KEY,
        payload jsonb NOT NULL,
        relay_claimed_until timestamptz,
        relayed_at timestamptz,
        relay_outcome text
      )
      """,
      []
    )

    password_file = Path.join(System.tmp_dir!(), "relay-outbox-" <> TenantFixture.random())
    File.write!(password_file, "relay\n")
    on_exit(fn -> File.rm(password_file) end)

    config = Application.fetch_env!(:relay, Relay.Repo)

    connector =
      Connector.parse!(
        name: :outbox_test,
        source: :outbox,
        access_tenant_id: tenant.attrs.access_tenant_id,
        access_client_id: client,
        concurrency: 2,
        options: [
          hostname: config[:hostname],
          port: config[:port],
          database: @database,
          username: "relay",
          password_file: password_file,
          table: table,
          poll_ms: 50
        ]
      )

    %{scope: tenant.live, conn: conn, table: table, connector: connector}
  end

  describe "T-41 L-42 INV-2 outbox source" do
    test "T-41: outbox rows are accepted or rejected once and their outcome is recorded", ctx do
      shipped = cloudevent("order-1", "com.shop.order.shipped")
      rows = [{1, shipped}, {2, cloudevent("order-2", "com.shop.unknown")}, {3, shipped}]

      for {id, event} <- rows do
        Postgrex.query!(
          ctx.conn,
          "INSERT INTO #{ctx.table} (id, payload) VALUES ($1, $2::text::jsonb)",
          [id, Jason.encode!(event)]
        )
      end

      start_supervised!(Relay.Connectors.child_spec(ctx.connector))
      deadline = System.monotonic_time(:millisecond) + 10_000

      assert outcomes(ctx.conn, ctx.table, deadline) == [
               [1, "accepted"],
               [2, "event_type_not_mapped"],
               [3, "accepted"]
             ]

      assert events(ctx.scope) == 1

      %{rows: [[claimed]]} =
        Postgrex.query!(
          ctx.conn,
          "SELECT count(*) FROM #{ctx.table} WHERE relayed_at IS NULL",
          []
        )

      assert claimed == 0
    end

    test "L-42: a row is taken by its state, so a row written later with a lower id is relayed",
         ctx do
      start_supervised!(Relay.Connectors.child_spec(ctx.connector))

      Postgrex.query!(
        ctx.conn,
        "INSERT INTO #{ctx.table} (id, payload) VALUES (20, $1::text::jsonb)",
        [Jason.encode!(cloudevent("order-20", "com.shop.order.shipped"))]
      )

      assert outcomes(ctx.conn, ctx.table, System.monotonic_time(:millisecond) + 10_000) ==
               [[20, "accepted"]]

      Postgrex.query!(
        ctx.conn,
        "INSERT INTO #{ctx.table} (id, payload) VALUES (10, $1::text::jsonb)",
        [Jason.encode!(cloudevent("order-10", "com.shop.order.shipped"))]
      )

      assert outcomes(ctx.conn, ctx.table, System.monotonic_time(:millisecond) + 10_000) ==
               [[10, "accepted"], [20, "accepted"]]

      assert events(ctx.scope) == 2
    end
  end
end
