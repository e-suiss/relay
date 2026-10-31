defmodule RelayWeb.Operator.Json do
  @moduledoc """
  The operator contract's response bodies (`contracts/openapi/operator.yaml`): external identifiers with their prefixes, RFC 3339 UTC times and `null` for absent values.
  """

  alias Relay.Api.Versions
  alias Relay.ExternalId
  alias Relay.Operators
  alias Relay.Operators.Authz
  alias Relay.Operators.Session

  @doc "An RFC 3339 time, or nil."
  @spec time(DateTime.t() | nil) :: String.t() | nil
  def time(nil), do: nil
  def time(%DateTime{} = at), do: DateTime.to_iso8601(%{at | microsecond: {0, 0}})

  @doc "An external identifier, or nil."
  @spec id(String.t(), Relay.Id.t() | nil) :: String.t() | nil
  def id(_prefix, nil), do: nil
  def id(prefix, id), do: ExternalId.encode(prefix, id)

  @doc "The operator of a session."
  @spec operator(Session.t()) :: map()
  def operator(%Session{} = session) do
    %{
      "object" => "operator",
      "id" => id("opr", session.operator_id),
      "display_name" => String.slice(session.subject, 0, 200),
      "status" => "active",
      "created_at" => time(session.operator_created_at || Relay.Clock.utc_now())
    }
  end

  # X-3
  @doc "An operator session with its role grants, step-up state and CSRF token."
  @spec session(Session.t(), String.t()) :: map()
  def session(%Session{} = session, csrf) do
    installation = Operators.installation_tenant_id()
    auth_time = session.auth_time || Relay.Clock.utc_now()

    valid_until =
      if Operators.step_up_fresh?(session),
        do: time(DateTime.add(session.step_up_at, Operators.step_up_window_s(), :second))

    %{
      "object" => "operator_session",
      "id" => id("oss", session.id || session.operator_id),
      "operator" => operator(session),
      "roles" => Enum.map(session.grants, &grant(&1, installation)),
      "auth_time" => time(auth_time),
      "step_up_valid_until" => valid_until,
      "expires_at" => time(session.expires_at || DateTime.add(auth_time, 43_200, :second)),
      "csrf_token" => csrf
    }
    |> put_present("acr", session.acr)
  end

  defp grant(%{role: :installation_operator}, _installation),
    do: %{"role" => "installation_operator", "tenant_id" => nil, "environment" => nil}

  defp grant(grant, _installation) do
    %{
      "role" => Atom.to_string(grant.role),
      "tenant_id" => id("ten", grant.tenant_id),
      "environment" => Atom.to_string(grant.environment)
    }
  end

  @doc "The built-in roles."
  @spec roles() :: [map()]
  def roles do
    descriptions = %{
      installation_operator:
        "The only role above tenants: platform kill switch, tenant suspension, the cross-tenant overview and the queue panel. It cannot read tenant data past row level security.",
      tenant_admin:
        "Administers one tenant and environment: roles, support delegation, send modes, audit log, API clients and personal data reveal.",
      tenant_operator: "Operates one tenant and environment."
    }

    for role <- Authz.roles() do
      %{
        "object" => "role",
        "key" => Atom.to_string(role),
        "scope" => if(role == :installation_operator, do: "installation", else: "tenant"),
        "rank" => Authz.rank(role),
        "description" => Map.fetch!(descriptions, role)
      }
    end
  end

  @doc "A role assignment."
  @spec role_assignment(map()) :: map()
  def role_assignment(row) do
    installation? = row["role"] == "installation_operator"

    %{
      "object" => "role_assignment",
      "id" => id("rla", row["id"]),
      "operator_id" => id("opr", row["operator_id"]),
      "role" => row["role"],
      "tenant_id" => if(installation?, do: nil, else: id("ten", row["tenant_id"])),
      "environment" => if(installation?, do: nil, else: row["environment"]),
      "status" => row["status"],
      "granted_by" => row["granted_by_ref"],
      "created_at" => time(row["created_at"]),
      "revoked_at" => time(row["revoked_at"]),
      "revoked_by" => row["revoked_by_ref"]
    }
  end

  @doc "A support delegation."
  @spec delegation(map()) :: map()
  def delegation(row) do
    %{
      "object" => "support_delegation",
      "id" => id("dlg", row["id"]),
      "operator_id" => id("opr", row["operator_id"]),
      "access" => row["access"],
      "reason" => row["reason"],
      "granted_by" => row["granted_by_ref"],
      "starts_at" => time(row["starts_at"]),
      "expires_at" => time(row["expires_at"]),
      "status" => row["status"],
      "revoked_at" => time(row["revoked_at"])
    }
  end

  @doc "A tenant or subtenant suspension."
  @spec suspension(map()) :: map()
  def suspension(row) do
    %{
      "object" => "tenant_suspension",
      "id" => id("tsp", row["id"]),
      "tenant_id" => id("ten", row["tenant_id"]),
      "subtenant_id" => id("stn", row["subtenant_id"]),
      "ground" => row["ground"],
      "reason" => row["reason"],
      "effective_at" => time(row["effective_at"]),
      "notice_due_at" => time(row["notice_due_at"]),
      "appeal_until" => time(row["appeal_until"]),
      "state" => row["state"],
      "created_by" => row["created_by_ref"],
      "created_at" => time(row["created_at"]),
      "lifted_at" => time(row["lifted_at"])
    }
  end

  # X-4
  @doc "The installation-level overview of a tenant: facts and counters, no record content."
  @spec tenant(map(), [map()] | nil) :: map()
  def tenant(row, suspensions) do
    %{
      "object" => "tenant_overview",
      "id" => id("ten", row["id"]),
      "access_tenant_id" => row["access_tenant_id"],
      "region" => row["region"],
      "status" => row["status"],
      "platform_product" => nil,
      "api_version" => date(row["api_version"]),
      "counters" => %{
        "notifications_24h" => row["notifications_24h"],
        "queued_deliveries" => row["queued_deliveries"],
        "paused_deliveries" => row["paused_deliveries"],
        "active_kill_switches" => row["active_kill_switches"]
      },
      "created_at" => time(row["created_at"])
    }
    |> put_present("suspensions", suspensions && Enum.map(suspensions, &suspension/1))
  end

  defp date(nil), do: nil
  defp date(%Date{} = date), do: Date.to_iso8601(date)
  defp date(text) when is_binary(text), do: text

  # OP-51
  @doc "A send mode level."
  @spec send_mode(map(), String.t()) :: map()
  def send_mode(row, level) do
    {category, channel} = levels(row["key"])

    %{
      "object" => "send_mode_setting",
      "level" => level,
      "category" => category,
      "channel" => channel,
      "mode" => row["mode"],
      "updated_at" => time(row["updated_at"]),
      "updated_by" => row["updated_by"] || "relay"
    }
  end

  @doc "The level name of a send mode settings key."
  @spec level(String.t()) :: String.t()
  def level("send_mode"), do: "tenant"
  def level("send_mode.channel." <> _), do: "channel"
  def level(_category), do: "category_channel"

  defp levels("send_mode.category." <> rest) do
    [category, channel] = String.split(rest, ".channel.", parts: 2)
    {category, channel}
  end

  defp levels("send_mode.channel." <> channel), do: {nil, channel}
  defp levels(_key), do: {nil, nil}

  @doc "An audit record."
  @spec audit(map()) :: map()
  def audit(row) do
    %{
      "object" => "audit_record",
      "id" => id("aud", row["id"]),
      "action" => row["action"],
      "actor_kind" => row["actor_kind"],
      "actor_ref" => row["actor_ref"],
      "on_behalf_of" => row["on_behalf_of_ref"],
      "access_record_ref" => row["access_record_ref"],
      "target_type" => row["target_type"],
      "target_id" => row["target_id"],
      "reason" => row["reason"],
      "created_at" => time(row["created_at"])
    }
  end

  # API-44
  # API-77 (2)
  @doc "The Relay-side view of an Access API client."
  @spec api_client(map(), Relay.Scope.t()) :: map()
  def api_client(client, %Relay.Scope{} = scope) do
    %{
      "object" => "api_client",
      "id" => id("cli", client.id),
      "access_client_id" => client.access_client_id,
      "environment" => Atom.to_string(scope.environment),
      "tenant" => nil,
      "scopes" => client.scopes,
      "status" => client.status,
      "last_used_at" => time(client.last_used_at),
      "last_used_ip" => nil,
      "unused_warning" => client.unused,
      "created_at" => time(client.created_at),
      "updated_at" => time(client.last_used_at || client.created_at)
    }
  end

  # API-52
  @doc "The API version pin of a tenant."
  @spec api_version(map()) :: map()
  def api_version(row) do
    %{
      "object" => "api_version",
      "pinned" => row["api_version"],
      "pinned_at" => time(row["api_version_pinned_at"]),
      "supported" => Versions.supported(),
      "latest" => Versions.latest()
    }
  end

  # TN-41
  @doc "A kill switch record."
  @spec kill_switch(map()) :: map()
  def kill_switch(record) do
    %{
      "object" => "kill_switch",
      "id" => id("ksw", record.id),
      "scope_kind" => Atom.to_string(record.scope_kind),
      "scope_ref" => record.scope_ref,
      "channel" => record.channel,
      "target_kind" => Atom.to_string(record.target_kind),
      "target_ref" => record.target_ref,
      "message_class" => record.message_class,
      "state" => Atom.to_string(record.state),
      "canary_percent" => record.canary_percent,
      "paused_until" => time(record.paused_until),
      "reason" => record.reason,
      "ticket_ref" => record.ticket_ref,
      "origin" => Atom.to_string(record.origin || :operator),
      "created_by" => record.created_by_ref,
      "expires_at" => time(record.expires_at),
      "supersedes_id" => id("ksw", record.supersedes_id),
      "status" => Atom.to_string(record.status),
      "released_at" => time(record.released_at),
      "released_by" => record.released_by_ref,
      "release_reason" => record.release_reason,
      "created_at" => time(record.created_at)
    }
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
