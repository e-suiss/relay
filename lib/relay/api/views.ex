defmodule Relay.Api.Views do
  @moduledoc """
  JSON views of the API resources (API-8, API-9): prefixed external identifiers, RFC 3339 times and the external delivery projection (DS-15), which maps the internal state of a delivery onto the contract's status set.
  """

  alias Relay.ExternalId

  @doc "Formats an identifier with its prefix; `nil` stays `nil`."
  @spec id(String.t(), Relay.Id.t() | nil) :: String.t() | nil
  def id(_prefix, nil), do: nil
  def id(prefix, id), do: ExternalId.encode(prefix, id)

  @doc "The prefix of a recipient by its kind."
  @spec recipient_prefix(String.t()) :: String.t()
  def recipient_prefix("agent"), do: "agt"
  def recipient_prefix(_subscriber), do: "sub"

  # API-19
  @doc "The accept answer of an event."
  @spec event_accepted(map()) :: map()
  def event_accepted(e) do
    %{
      "object" => "event",
      "id" => id("evt", e.id),
      "workflow" => %{"key" => e.workflow_key, "version" => e.workflow_version},
      "status" => "accepted",
      "recipient_count" => e.recipient_count,
      "notifications" => e.notifications,
      "created_at" => e.created_at
    }
    |> put_unless_empty("warnings", e.warnings)
  end

  # API-19
  @doc "One accepted notification of an event answer."
  @spec accepted_notification(map()) :: map()
  def accepted_notification(n) do
    %{
      "recipient_id" => id(recipient_prefix(n.recipient_kind), n.recipient_id),
      "external_id" => n.external_id,
      "notification_id" => id("ntf", n.notification_id)
    }
    |> put_unless_nil("duplicate_of", id("evt", n.duplicate_of))
  end

  # DS-15
  @doc "The external status of a delivery from its projection columns."
  @spec status(map()) :: String.t()
  def status(%{"status" => status}) when is_binary(status), do: status

  @doc "A delivery."
  @spec delivery(map()) :: map()
  def delivery(d) do
    {reason, rule_id} = reason(d)

    %{
      "object" => "delivery",
      "id" => id("dlv", d["id"]),
      "notification_id" => id("ntf", d["notification_id"]),
      "channel" => d["channel"],
      "status" => status(d),
      "reason" => reason,
      "rule_id" => rule_id,
      "deferred_until" => d["deferred_until"],
      "failure" => failure(d),
      "fallback_of" => id("dlv", d["fallback_of"]),
      "accepted_at" => d["accepted_at"],
      "delivered_at" => d["delivered_at"],
      "created_at" => d["created_at"],
      "updated_at" => d["updated_at"]
    }
  end

  defp reason(%{"failure_kind" => kind} = d) when kind != nil,
    do: {d["failure_reason"] || kind, rule(d["failure_rule_id"])}

  defp reason(%{"paused_at" => paused} = d) when paused != nil,
    do: {"paused", rule(d["pause_rule_id"])}

  defp reason(d), do: {d["decision_reason"], rule(d["decision_rule_id"])}

  defp rule(nil), do: nil

  defp rule(rule) do
    if Regex.match?(~r/^[a-z][a-z0-9_]*([.:][A-Za-z0-9_-]+)*$/, rule) and
         String.length(rule) <= 128,
       do: rule,
       else: nil
  end

  defp failure(%{"failure_kind" => kind, "failure_class" => class})
       when kind in ["failed", "bounced"] and class != nil,
       do: %{"kind" => kind, "class" => class, "retryable" => class == "transient"}

  defp failure(_d), do: nil

  # DS-15
  @doc "A notification of an event."
  @spec notification(map(), [map()] | nil) :: map()
  def notification(n, deliveries \\ nil) do
    %{
      "object" => "notification",
      "id" => id("ntf", n["id"]),
      "event_id" => id("evt", n["event_id"]),
      "workflow" => %{"key" => n["workflow_key"], "version" => n["workflow_version"]},
      "recipient_id" => id(recipient_prefix(n["recipient_kind"]), n["recipient_id"]),
      "tenant" => id("stn", n["subtenant_id"]),
      "message_class" => n["message_class"],
      "security_subtype" => n["security_subtype"],
      "sender_type" => n["sender_type"],
      "dedup_key" => n["dedup_key"],
      "state" => n["state"],
      "close_rule_id" => rule(n["close_rule_id"]),
      "expires_at" => n["expires_at"],
      "duplicate_count" => n["duplicate_count"],
      "delivery_counts" => n["delivery_counts"] || %{},
      "is_test" => n["is_test"],
      "created_at" => n["created_at"],
      "updated_at" => n["updated_at"]
    }
    |> put_unless_nil("deliveries", deliveries && Enum.map(deliveries, &delivery/1))
  end

  @doc "A cancellation result; the function's details carry plain identifiers."
  @spec cancellation(Relay.Id.t(), map()) :: map()
  def cancellation(id, row) do
    details =
      for detail <- row["details"] || [] do
        %{"result" => detail["result"]}
        |> put_unless_nil("notification_id", text_id("ntf", detail["notification_id"]))
        |> put_unless_nil("delivery_id", text_id("dlv", detail["delivery_id"]))
      end

    %{
      "object" => "cancellation",
      "id" => id("cnl", id),
      "cancelled" => row["cancelled"] || 0,
      "already_sent" => row["already_sent"] || 0,
      "not_found" => row["not_found"] || 0,
      "details" => details,
      "has_more" => row["has_more"] || false
    }
  end

  defp text_id(_prefix, nil), do: nil

  defp text_id(prefix, text) do
    case Relay.Id.parse(text) do
      {:ok, id} -> id(prefix, id)
      {:error, _error} -> nil
    end
  end

  @doc "Puts a value unless it is `nil`."
  @spec put_unless_nil(map(), String.t(), term()) :: map()
  def put_unless_nil(map, _key, nil), do: map
  def put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp put_unless_empty(map, _key, []), do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)
end
