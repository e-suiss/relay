defmodule Relay.Schema.ContractDriftTest do
  use Relay.SqlCase, async: false

  @events Path.expand("../../../contracts/asyncapi/events.yaml", __DIR__)

  @domain "SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c WHERE c.contypid = $1::text::regtype"
  @column "SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c WHERE c.conrelid = $1::text::regclass AND c.conname = $2"
  @source "SELECT p.prosrc FROM pg_proc p WHERE p.oid = $1::text::regproc"

  @overview ["components", "schemas", "TenantOverview", "properties"]
  @operator_schemas ["components", "schemas"]

  @domains [
    {"relay.environment", {"schemas", ["Environment"]}},
    {"relay.region", {"operator", @overview ++ ["region"]}},
    {"relay.message_class", {"schemas", ["MessageClass"]}},
    {"relay.channel", {"schemas", ["Channel"]}},
    {"relay.send_mode", {"schemas", ["SendMode"]}},
    {"relay.api_scope", {"schemas", ["ScopeName"]}},
    {"relay.failure_class", {"schemas", ["Failure", "properties", "class"]}},
    {"relay.actor_kind",
     {"operator", @operator_schemas ++ ["AuditRecord", "properties", "actor_kind"]}}
  ]

  @columns [
    {"relay.tenants", "tenants_status_check", {"operator", @overview ++ ["status"]}},
    {"relay.tenants", "tenants_platform_product_check",
     {"operator", @overview ++ ["platform_product", "oneOf", 0]}},
    {"relay.recipients", "recipients_state_check",
     {"schemas", ["Subscriber", "properties", "state"]}},
    {"relay.recipients", "recipients_legal_type_check", {"schemas", ["LegalType"]}},
    {"relay.recipient_deletion_requests", "recipient_deletion_requests_status_check",
     {"schemas", ["SubscriberDeletion", "properties", "status"]}},
    {"relay.notifications", "notifications_security_subtype_check",
     {"schemas", ["SecuritySubtype"]}},
    {"relay.notifications", "notifications_sender_type_check",
     {"schemas", ["Notification", "properties", "sender_type"]}},
    {"relay.notifications", "notifications_state_check",
     {"schemas", ["Notification", "properties", "state"]}},
    {"relay.deliveries", "deliveries_failure_class_check",
     {"schemas", ["Failure", "properties", "class"]}},
    {"relay.delivery_attempts", "delivery_attempts_state_check",
     {"schemas", ["Attempt", "properties", "state"]}},
    {"relay.delivery_attempts", "delivery_attempts_failure_class_check",
     {"schemas", ["Failure", "properties", "class"]}},
    {"relay.delivery_events", "delivery_events_actor_check",
     {"schemas", ["LedgerEvent", "properties", "actor"]}},
    {"relay.events", "events_source_check", {"schemas", ["Event", "properties", "source"]}},
    {"relay.events", "events_sender_type_check", {"schemas", ["Actor", "properties", "type"]}},
    {"relay.events", "events_priority_check", {"schemas", ["Priority"]}},
    {"relay.events", "events_security_subtype_check", {"schemas", ["SecuritySubtype"]}},
    {"relay.events", "events_on_expire_check", {"schemas", ["OnExpire"]}},
    {"relay.events", "events_state_check", {"schemas", ["Event", "properties", "status"]}},
    {"relay.event_type_mappings", "event_type_mappings_state_check",
     {"schemas", ["EventTypeMapping", "properties", "state"]}},
    {"relay.workflows", "workflows_managed_by_check",
     {"schemas", ["Workflow", "properties", "managed_by"]}},
    {"relay.workflows", "workflows_state_check",
     {"schemas", ["Workflow", "properties", "state"]}},
    {"relay.kill_switches", "kill_switches_scope_kind_check",
     {"schemas", ["KillSwitch", "properties", "scope_kind"]}},
    {"relay.kill_switches", "kill_switches_target_kind_check",
     {"schemas", ["KillSwitch", "properties", "target_kind"]}},
    {"relay.kill_switches", "kill_switches_state_check",
     {"schemas", ["KillSwitch", "properties", "state"]}},
    {"relay.kill_switches", "kill_switches_origin_check",
     {"schemas", ["KillSwitch", "properties", "origin"]}},
    {"relay.kill_switches", "kill_switches_status_check",
     {"schemas", ["KillSwitch", "properties", "status"]}},
    {"relay.api_clients", "api_clients_status_check",
     {"operator", @operator_schemas ++ ["ApiClient", "properties", "status"]}},
    {"relay.operators", "operators_status_check",
     {"operator", @operator_schemas ++ ["Operator", "properties", "status"]}},
    {"relay.role_assignments", "role_assignments_role_check",
     {"operator", @operator_schemas ++ ["RoleAssignment", "properties", "role"]}},
    {"relay.role_assignments", "role_assignments_role_check",
     {"schemas", ["Role", "properties", "key"]}},
    {"relay.role_assignments", "role_assignments_status_check",
     {"operator", @operator_schemas ++ ["RoleAssignment", "properties", "status"]}},
    {"relay.support_delegations", "support_delegations_access_check",
     {"operator", @operator_schemas ++ ["SupportDelegation", "properties", "access"]}},
    {"relay.support_delegations", "support_delegations_status_check",
     {"operator", @operator_schemas ++ ["SupportDelegation", "properties", "status"]}},
    {"relay.tenant_suspensions", "tenant_suspensions_ground_check",
     {"operator", @operator_schemas ++ ["TenantSuspension", "properties", "ground"]}},
    {"relay.tenant_suspensions", "tenant_suspensions_ground_check",
     {"operator", @operator_schemas ++ ["SuspendRequest", "properties", "ground"]}},
    {"relay.tenant_suspensions", "tenant_suspensions_state_check",
     {"operator", @operator_schemas ++ ["TenantSuspension", "properties", "state"]}},
    {"relay.quota_policies", "quota_policies_period_check",
     {"operator", @operator_schemas ++ ["QuotaPolicy", "properties", "period"]}}
  ]

  defp values(definition), do: ~r/'([^']*)'/ |> Regex.scan(definition) |> Enum.map(&List.last/1)

  defp domain(name) do
    [[definition]] = rows(@domain, [name])
    Enum.sort(values(definition))
  end

  defp column(table, constraint) do
    assert [[definition]] = rows(@column, [table, constraint]), "#{table} #{constraint}"
    Enum.sort(values(definition))
  end

  defp dig(value, []), do: value
  defp dig(list, [index | rest]) when is_list(list), do: dig(Enum.at(list, index), rest)
  defp dig(map, [key | rest]) when is_map(map), do: dig(Map.get(map, key), rest)
  defp dig(_value, _path), do: nil

  defp contract({document, path}) do
    case dig(Relay.Api.Contract.documents()[document], path) do
      %{"enum" => enum} -> Enum.sort(enum)
      other -> flunk("no enum at #{document} #{inspect(path)}: #{inspect(other)}")
    end
  end

  defp property_enums(value, name) when is_map(value) do
    own =
      case value do
        %{^name => %{"enum" => enum}} -> [Enum.sort(enum)]
        _other -> []
      end

    own ++ Enum.flat_map(Map.values(value), &property_enums(&1, name))
  end

  defp property_enums(value, name) when is_list(value),
    do: Enum.flat_map(value, &property_enums(&1, name))

  defp property_enums(_value, _name), do: []

  defp ttl_intervals(function) do
    for [_, hours] <- Regex.scan(~r/interval '(\d+) hours'/, one(@source, [function])),
        do: String.to_integer(hours)
  end

  describe "API-2 MD-13 contract and database value sets" do
    test "API-2, MD-13: every domain value set equals its contract enum" do
      for {name, ref} <- @domains do
        assert domain(name) == contract(ref), name
      end
    end

    test "API-2, MD-13: every column value set equals its contract enum" do
      for {table, constraint, ref} <- @columns do
        assert column(table, constraint) == contract(ref), "#{table} #{constraint}"
      end
    end

    test "API-2, MD-13, TN-48: every actor_kind enum of the event catalog equals the actor_kind domain" do
      kinds = domain("relay.actor_kind")
      enums = @events |> YamlElixir.read_from_file!() |> property_enums("actor_kind")

      assert enums != []
      for enum <- enums, do: assert(enum == kinds)
    end

    test "API-2, MD-13, API-11: the idempotency key domain and retention follow x-relay-limits" do
      limits = Relay.Limits.all()
      [[definition]] = rows(@domain, ["relay.idempotency_key"])
      bounds = for [n] <- Regex.scan(~r/\d+/, definition), do: String.to_integer(n)
      key_length = limits["idempotency_key_length"]
      assert Enum.sort(bounds) == [key_length["min"], key_length["max"]]

      intervals =
        ttl_intervals("relay_fn.idempotency_begin") ++
          ttl_intervals("relay_fn.idempotency_complete")

      assert intervals != []
      assert Enum.uniq(intervals) == [limits["idempotency_key_ttl_hours"]]
    end
  end
end
