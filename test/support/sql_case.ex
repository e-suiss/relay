defmodule Relay.SqlCase do
  @moduledoc """
  Case template for SQL-level tests of the `relay_fn`, `relay_ops` and `relay_private` functions. Queries run in the SQL sandbox transaction of `Relay.Repo` (the `relay_worker` login) unless `on/2` routes them to an unsandboxed connection of another login; the functions are driven directly with SQL, without the Elixir data layer.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias Ecto.Adapters.SQL.Sandbox
  alias Relay.Repo

  using do
    quote do
      @moduletag :integration
      import Relay.SqlCase
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc "Returns a fresh UUIDv7 for the current time."
  @spec id() :: <<_::128>>
  def id, do: Relay.Id.build(System.os_time(:millisecond), :crypto.strong_rand_bytes(10))

  @doc "Returns 32 random bytes, the shape of a SHA-256 digest."
  @spec digest() :: binary()
  def digest, do: :crypto.strong_rand_bytes(32)

  @doc "Returns the four actor parameters in function order."
  @spec actor() :: [String.t() | nil]
  def actor, do: ["operator", "acc_op_1", "acc_op_1", nil]

  @doc "Runs `sql` on the current connection and returns its rows."
  @spec rows(String.t(), list()) :: [list()]
  def rows(sql, params \\ []) do
    case query!(sql, params) do
      %{rows: nil} -> []
      %{rows: rows} -> rows
    end
  end

  @doc "Runs `sql` and returns the single value of its single row."
  @spec one(String.t(), list()) :: term()
  def one(sql, params \\ []) do
    [[value]] = rows(sql, params)
    value
  end

  @doc "Runs `sql` and returns its single row."
  @spec row(String.t(), list()) :: list()
  def row(sql, params \\ []) do
    [row] = rows(sql, params)
    row
  end

  @doc "Runs `sql` inside a savepoint that is rolled back and returns the PostgreSQL error."
  @spec sql_error(String.t(), list()) :: Postgrex.Error.t()
  def sql_error(sql, params \\ []) do
    {:error, %Postgrex.Error{} = error} =
      case Process.get(:relay_sql_conn) do
        nil ->
          Repo.query(sql, params)

        conn ->
          Postgrex.query!(conn, "SAVEPOINT relay_sql_error", [])
          result = Postgrex.query(conn, sql, params)
          Postgrex.query!(conn, "ROLLBACK TO SAVEPOINT relay_sql_error", [])
          result
      end

    error
  end

  @doc "Returns the message of the PostgreSQL error raised by `sql`."
  @spec error_message(String.t(), list()) :: String.t()
  def error_message(sql, params \\ []), do: sql_error(sql, params).postgres.message

  @doc "Opens an unsandboxed connection as the local login `login` (`:admin` or a role name)."
  @spec connect(:admin | String.t()) :: pid()
  def connect(login) do
    username = if login == :admin, do: "relay", else: login

    opts =
      :relay
      |> Application.fetch_env!(Repo)
      |> Keyword.take([:hostname, :port, :database, :socket_dir, :ssl])
      |> Keyword.merge(username: username, password: "relay")

    {:ok, conn} = Postgrex.start_link(opts)
    conn
  end

  @doc "Runs `fun` with every query of this module routed to `conn`."
  @spec on(pid(), (-> result)) :: result when result: term()
  def on(conn, fun) do
    previous = Process.put(:relay_sql_conn, conn)

    try do
      fun.()
    after
      if previous,
        do: Process.put(:relay_sql_conn, previous),
        else: Process.delete(:relay_sql_conn)
    end
  end

  @doc "Runs `fun` on `conn` inside a transaction that is committed."
  @spec committed(pid(), (-> result)) :: result when result: term()
  def committed(conn, fun) do
    on(conn, fn ->
      query!("BEGIN", [])
      result = fun.()
      query!("COMMIT", [])
      result
    end)
  end

  @doc "Runs `fun` on `conn` inside a transaction that is rolled back."
  @spec rolled_back(pid(), (-> result)) :: result when result: term()
  def rolled_back(conn, fun) do
    on(conn, fn ->
      query!("BEGIN", [])

      try do
        fun.()
      after
        query!("ROLLBACK", [])
      end
    end)
  end

  @doc "Sets the tenant context for the transaction and returns the tenant status."
  @spec ctx(binary(), String.t()) :: String.t()
  def ctx(tenant_id, environment \\ "test"),
    do: one("SELECT relay_fn.ctx_set($1, $2)", [tenant_id, environment])

  @doc "Returns the installation region."
  @spec region() :: String.t()
  def region, do: one("SELECT region FROM relay.installation")

  @doc "Creates an active tenant through `relay_ops.tenant_create` and returns its ID."
  @spec tenant!() :: binary()
  def tenant! do
    tenant_id = id()

    ["created", ^tenant_id] =
      row(
        "SELECT * FROM relay_ops.tenant_create($1, $2, $3, 'general', 'Europe/Istanbul', 'tr', NULL, NULL, $4, $5, $6, $7, $8)",
        [tenant_id, "acc_" <> Base.encode16(tenant_id), region(), digest() | actor()]
      )

    tenant_id
  end

  @doc "Registers a tenant key of `purpose` in the current context and returns its ID."
  @spec tenant_key!(String.t(), Date.t() | nil) :: binary()
  def tenant_key!(purpose \\ "data", valid_day \\ nil) do
    key_id = id()

    "created" =
      one(
        "SELECT relay_fn.tenant_key_register($1, $2, $3, 'pkcs11:token=relay;object=kek', $4, $5, $6, $7, $8, $9)",
        [key_id, purpose, valid_day, :crypto.strong_rand_bytes(61), digest() | actor()]
      )

    key_id
  end

  @doc "Registers the blind index key of the current context and returns its ID."
  @spec blind_index_key!() :: binary()
  def blind_index_key! do
    key_id = id()

    "created" =
      one(
        "SELECT relay_fn.blind_index_key_register($1, 'pkcs11:token=relay;object=bidx', $2, $3, $4, $5, $6)",
        [key_id, digest() | actor()]
      )

    key_id
  end

  @doc "Creates a subscriber recipient with its profile key and returns the recipient ID."
  @spec recipient!(binary(), binary()) :: binary()
  def recipient!(bidx_key_id, wrap_key_id) do
    recipient_id = id()

    ["created", ^recipient_id] =
      row(
        "SELECT * FROM relay_fn.recipient_create($1, 'subscriber', $2, $3, $4, $5, $6, $7)",
        [
          recipient_id,
          digest(),
          bidx_key_id,
          :crypto.strong_rand_bytes(40),
          id(),
          :crypto.strong_rand_bytes(60),
          wrap_key_id
        ]
      )

    recipient_id
  end

  @doc "Accepts a notification for `recipient_id` and returns its ID."
  @spec notification!(binary(), String.t()) :: binary()
  def notification!(recipient_id, dedup_key \\ "dedup:" <> Base.encode16(digest())) do
    notification_id = id()

    ["created", ^notification_id] =
      row(
        "SELECT * FROM relay_fn.notification_accept($1, $2, NULL, $3, 'transactional', NULL, 'system', NULL, NULL, NULL, false, NULL)",
        [notification_id, recipient_id, dedup_key]
      )

    notification_id
  end

  @doc "Opens a delivery on `channel` with decision `send` and returns its ID."
  @spec delivery!(binary(), String.t(), binary()) :: binary()
  def delivery!(notification_id, channel \\ "sms", target_key \\ digest()) do
    delivery_id = id()

    ["opened", ^delivery_id] =
      row(
        "SELECT * FROM relay_fn.delivery_open($1, $2, $3, 'address', NULL, $4, 'acme_sms', NULL, NULL, 'send', NULL, NULL, NULL, NULL)",
        [delivery_id, notification_id, channel, target_key]
      )

    delivery_id
  end

  @doc "Builds a tenant with its keys, a recipient and a notification and returns them in a map."
  @spec scenario!() :: %{
          tenant: binary(),
          data_key: binary(),
          bidx_key: binary(),
          recipient: binary(),
          notification: binary()
        }
  def scenario! do
    tenant = tenant!()
    "active" = ctx(tenant)
    data_key = tenant_key!("data")
    wrap_key = tenant_key!("dek_wrap")
    bidx_key = blind_index_key!()
    recipient = recipient!(bidx_key, wrap_key)

    %{
      tenant: tenant,
      data_key: data_key,
      bidx_key: bidx_key,
      recipient: recipient,
      notification: notification!(recipient)
    }
  end

  @doc "Appends a ledger event and returns `[result, delivery_rank, projection_version]`."
  @spec ledger!(binary(), keyword()) :: list()
  def ledger!(delivery_id, opts) do
    row(
      "SELECT * FROM relay_fn.ledger_append($1, $2, $3, $4, $5, $6, 'acme_sms', $7, $8, $9, $10, $11, $12, $13, $14, $15, NULL)",
      [
        id(),
        delivery_id,
        opts[:attempt_no],
        opts[:actor] || "provider_webhook",
        opts[:event_type] || "dlr.delivered",
        opts[:raw_code],
        opts[:provider_seq],
        opts[:occurred_at] || DateTime.utc_now(),
        opts[:receipt_id],
        opts[:rank],
        opts[:failure_kind],
        opts[:failure_class],
        opts[:failure_rule_id],
        opts[:after_delivered],
        opts[:detail]
      ]
    )
  end

  @doc "Asserts that the projection of `delivery_id` rebuilds from its ledger without a difference."
  @spec assert_rebuilds(binary()) :: true
  def assert_rebuilds(delivery_id) do
    assert rows("SELECT * FROM relay_fn.delivery_projection_rebuild($1)", [delivery_id]) == []
  end

  defp query!(sql, params) do
    case Process.get(:relay_sql_conn) do
      nil -> Repo.query!(sql, params)
      conn -> Postgrex.query!(conn, sql, params)
    end
  end
end
