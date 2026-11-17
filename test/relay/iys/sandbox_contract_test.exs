defmodule Relay.Iys.SandboxContractTest do
  use ExUnit.Case, async: false

  alias Relay.Iys.Client
  alias Relay.Iys.TokenCache
  alias Relay.Redacted

  @moduletag :iys_sandbox
  @moduletag timeout: 120_000

  @sandbox "https://api.sandbox.iys.org.tr"

  setup_all do
    previous = Application.get_env(:relay, Relay.Iys, [])
    Application.put_env(:relay, Relay.Iys, Keyword.delete(previous, :http))
    on_exit(fn -> Application.put_env(:relay, Relay.Iys, previous) end)
    cache = start_supervised!({TokenCache, name: nil})

    conn = %{
      base_url: @sandbox,
      iys_code: String.to_integer(System.fetch_env!("IYS_SANDBOX_IYS_CODE")),
      integrator_code: nil,
      username: System.fetch_env!("IYS_SANDBOX_USERNAME"),
      password: Redacted.wrap(System.fetch_env!("IYS_SANDBOX_PASSWORD")),
      cache_key: {:sandbox, System.unique_integer()},
      cache: cache
    }

    %{conn: conn, brand: String.to_integer(System.fetch_env!("IYS_SANDBOX_BRAND_CODE"))}
  end

  defp consent(status, seconds_ago) do
    name = "relay-contract-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    %{
      recipient: name <> "@example.com",
      type: "EPOSTA",
      status: status,
      recipient_type: "BIREYSEL",
      source: "HS_WEB",
      consent_at: DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
    }
  end

  describe "PC-56 the İYS sandbox" do
    test "PC-56, PC-34: a token is issued once and the subscription carries the quota", ctx do
      assert {:ok, first} = Client.token(ctx.conn)
      assert {:ok, second} = Client.token(ctx.conn)
      assert Redacted.expose(first) == Redacted.expose(second)

      assert {:ok, subscription} = Client.subscription(ctx.conn)
      assert is_integer(subscription.consent_limit)
      assert is_integer(subscription.used_consent_limit)

      assert {:ok, brands} = Client.brands(ctx.conn)
      assert Enum.any?(brands, &(&1.brand_code == ctx.brand))
    end

    test "PC-56, PC-30: a consent is added idempotently and read back", ctx do
      movement = consent("ONAY", 120)

      assert {:ok, added} = Client.add_consent(ctx.conn, ctx.brand, movement)
      assert {:ok, again} = Client.add_consent(ctx.conn, ctx.brand, movement)
      assert again.transaction_id == added.transaction_id
      assert %DateTime{} = added.registered_at

      query = Map.take(movement, [:recipient, :type, :recipient_type])
      assert {:ok, %{status: "ONAY"} = held} = Client.consent_status(ctx.conn, ctx.brand, query)
      assert held.transaction_id == added.transaction_id

      Process.sleep(2_000)
      refusal = %{movement | status: "RET", consent_at: DateTime.utc_now()}
      assert {:ok, _refused} = Client.add_consent(ctx.conn, ctx.brand, refusal)
      assert {:ok, %{status: "RET"}} = Client.consent_status(ctx.conn, ctx.brand, query)
    end

    test "PC-56, PC-30: İYS refuses a first record that is RET and an unknown recipient is nil",
         ctx do
      refusal = consent("RET", 60)

      assert {:error, %{class: :rejected, code: "H175"}} =
               Client.add_consent(ctx.conn, ctx.brand, refusal)

      query = Map.take(refusal, [:recipient, :type, :recipient_type])
      assert {:ok, nil} = Client.consent_status(ctx.conn, ctx.brand, query)
    end

    test "PC-56, PC-34: a batch is accepted and its status and the changes can be read", ctx do
      list = [consent("ONAY", 90), consent("ONAY", 80)]

      assert {:ok, %{request_id: request_id}} = Client.add_batch(ctx.conn, ctx.brand, list)
      assert {:ok, items} = Client.batch_status(ctx.conn, ctx.brand, request_id)
      assert is_list(items)

      assert {:ok, %{list: changes}} = Client.changes(ctx.conn, ctx.brand, source: "HS")
      assert is_list(changes)
    end
  end
end
