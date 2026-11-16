defmodule Relay.Webhooks.SchemaTest do
  use Relay.DataCase, async: true

  alias Relay.Repo

  @terminal ~w(delivered failed_permanent exhausted expired window_exceeded dead_lettered
               cancelled)
  @waiting ~w(pending scheduled in_flight held)
  @kinds ~w(https kafka nats_jetstream rabbitmq aws_sqs aws_sns aws_eventbridge gcp_pubsub
            azure_service_bus azure_event_grid s3)

  defp rows(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp values(table, constraint) do
    sql = """
    SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c
    WHERE c.conrelid = $1::text::regclass AND c.conname = $2
    """

    [[definition]] = rows(sql, ["relay." <> table, constraint])

    ~r/'([^']*)'/ |> Regex.scan(definition) |> Enum.map(&List.last/1) |> Enum.sort()
  end

  defp enum(name), do: Relay.Api.Contract.documents()["schemas"][name]["enum"]

  describe "WH-2 INV-12 one message per event and endpoint" do
    test "WH-2, INV-12: (endpoint_id, event_id) is unique in the tenant environment on a table that is not partitioned" do
      assert rows("""
             SELECT c.relkind::text, pg_get_constraintdef(k.oid)
             FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid
             WHERE k.conname = 'webhook_messages_endpoint_event_key'
             """) == [["r", "UNIQUE (tenant_id, environment, endpoint_id, event_id)"]]

      events = "SELECT relkind::text FROM pg_class WHERE oid = 'relay.webhook_events'::regclass"
      assert rows(events) == [["r"]]

      assert rows("""
             SELECT c.relkind::text, pg_get_partkeydef(c.oid)
             FROM pg_class c WHERE c.oid = 'relay.webhook_attempts'::regclass
             """) == [["p", "RANGE (created_at)"]]
    end
  end

  describe "WH-27 WH-17 contract value sets" do
    test "WH-27: the message states are the contract's, and its terminal states are exactly the seven of the decision" do
      assert values("webhook_messages", "webhook_messages_state_check") ==
               Enum.sort(enum("WebhookMessageState"))

      assert Enum.sort(enum("WebhookMessageState")) == Enum.sort(@terminal ++ @waiting)
      assert Enum.sort(["delivered" | enum("WebhookMessageFailedState")]) == Enum.sort(@terminal)

      [[terminal]] =
        rows("""
        SELECT pg_get_constraintdef(k.oid) FROM pg_constraint k
        WHERE k.conname = 'webhook_messages_terminal_check'
        """)

      for state <- @terminal, do: assert(terminal =~ "'#{state}'", state)
      for state <- @waiting, do: refute(terminal =~ "'#{state}'", state)
    end

    test "WH-17: the destination kinds, endpoint states and signature schemes are the contract's" do
      assert values("webhook_endpoints", "webhook_endpoints_kind_check") == Enum.sort(@kinds)
      assert Enum.sort(enum("WebhookDestinationKind")) == Enum.sort(@kinds)

      assert values("webhook_endpoints", "webhook_endpoints_state_check") ==
               Enum.sort(enum("WebhookEndpointState"))

      assert values("webhook_endpoints", "webhook_endpoints_use_kind_check") ==
               Enum.sort(enum("WebhookEndpointUse"))

      assert values("webhook_endpoints", "webhook_endpoints_disabled_reason_check") ==
               Enum.sort(enum("WebhookEndpointDisabledReason"))

      assert values("webhook_endpoint_keys", "webhook_endpoint_keys_scheme_check") ==
               Enum.sort(enum("SignatureScheme"))
    end
  end

  describe "WH-30 WH-37 missed events" do
    test "WH-30 (2), WH-37: missed events are one indexed predicate: failed terminal messages and those held for a disabled endpoint" do
      [[definition]] =
        rows("SELECT indexdef FROM pg_indexes WHERE indexname = 'webhook_messages_missed_index'")

      assert definition =~ "(tenant_id, environment, endpoint_id, created_at, id)"
      assert definition =~ "hold_reason = 'endpoint_disabled'"
      for state <- @terminal -- ["delivered"], do: assert(definition =~ "'#{state}'", state)
      refute definition =~ "'delivered'"
    end
  end

  describe "WH-5 WH-19 secrets" do
    test "WH-5, WH-19: a signing key keeps only a sealed secret, and an endpoint names its credential by reference" do
      columns =
        rows("""
        SELECT c.relname::text, a.attname::text FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'relay' AND c.relname IN ('webhook_endpoints', 'webhook_endpoint_keys')
          AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname ~ '(secret|password|private|token|credential)'
        ORDER BY 1, 2
        """)

      assert columns == [
               ["webhook_endpoint_keys", "secret_ct"],
               ["webhook_endpoint_keys", "secret_key_id"],
               ["webhook_endpoints", "credential_ref_id"]
             ]

      assert rows("""
             SELECT r.relname::text FROM pg_constraint k JOIN pg_class r ON r.oid = k.confrelid
             WHERE k.conname = 'webhook_endpoints_credential_ref_id_fkey'
             """) == [["secret_refs"]]
    end
  end
end
