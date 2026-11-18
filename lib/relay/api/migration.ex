defmodule Relay.Api.Migration do
  @moduledoc """
  The migration operations of the server API (OP-52 … OP-54, OP-79, OP-94, OP-95) and the subscriber's displayed notification telemetry: the existing system's shadow reports (`POST /v1/shadow/observations`), the shadow coverage report, the intentional differences, the staged rollout configuration with its emergency stop, the dedup claims of the shared uniqueness store and the shadow flag of a webhook endpoint. Each answers `{status, headers, body}` for `RelayWeb.Api.Work`.
  """

  alias Relay.Api.Page
  alias Relay.Api.Views

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @min_ttl_s Relay.Limits.seconds!(["dedup_claim", "min_ttl"])
  @max_ttl_s Relay.Limits.seconds!(["dedup_claim", "max_ttl"])

  # OP-94
  # OP-52 (2)
  @doc "Records the existing system's report of a request and answers its counts; runs outside any transaction."
  @spec observe(Relay.Scope.t(), map()) :: answer()
  def observe(scope, body) do
    case Relay.Migration.observe(scope, body) do
      {:ok, result} ->
        {:ok,
         {202, [],
          %{
            "object" => "shadow_observation",
            "correlation_id" => result.correlation_id,
            "recorded" => result.recorded,
            "compared" => result.compared,
            "unknown_recipients" => result.unknown_recipients
          }}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # OP-79
  # OP-94
  @doc "Answers the shadow coverage report."
  @spec coverage(Relay.Scope.t()) :: answer()
  def coverage(scope) do
    case Relay.Migration.coverage(scope) do
      {:ok, report} -> {:ok, {200, [], coverage_view(report)}}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # OP-79
  @doc "Answers a page of intentional differences."
  @spec differences(Relay.Scope.t(), map(), String.t()) :: answer()
  def differences(scope, page, endpoint) do
    after_id = page.cursor && page.cursor.id

    with {:ok, rows} <- Relay.Migration.differences(scope, after_id, page.limit + 1) do
      page = %{page | cursor: page.cursor && %{page.cursor | direction: :after}}
      position = &{&1["created_at"], &1["id"]}

      envelope = Page.envelope(rows, page, scope, endpoint, &difference_view/1, position)
      with {:ok, body} <- envelope, do: {:ok, {200, [], body}}
    end
  end

  # OP-52 (3)
  # OP-79
  @doc "Records an intentional difference inside its own transaction and answers it."
  @spec create_difference(Relay.Scope.t(), map(), Relay.Actor.t()) :: answer()
  def create_difference(scope, body, actor) do
    with {:ok, expires_at} <- time(body["expires_at"], "/expires_at") do
      attrs = %{
        id: Relay.Id.generate(),
        layer: body["layer"],
        field: body["field"],
        template_key: body["template"],
        channel: body["channel"],
        owner: body["owner"],
        reason: body["reason"],
        expires_at: expires_at
      }

      case Relay.Migration.create_difference(scope, attrs, actor) do
        {:ok, %{} = row} -> {:ok, {201, [location(row)], difference_view(row)}}
        {:error, :invalid_expiry} -> {:error, expiry_error()}
        {:error, _reason} -> {:error, unavailable()}
      end
    end
  end

  # OP-79
  @doc "Moves the expiry of an intentional difference inside its own transaction and answers it."
  @spec renew_difference(Relay.Scope.t(), Relay.Id.t(), map(), Relay.Actor.t()) :: answer()
  def renew_difference(scope, id, body, actor) do
    with {:ok, expires_at} <- time(body["expires_at"], "/expires_at") do
      case Relay.Migration.renew_difference(scope, id, expires_at, body["reason"], actor) do
        {:ok, %{} = row} -> {:ok, {200, [], difference_view(row)}}
        {:error, :not_found} -> {:error, difference_not_found()}
        {:error, :invalid_expiry} -> {:error, expiry_error()}
        {:error, _reason} -> {:error, unavailable()}
      end
    end
  end

  @doc "The error of an unknown intentional difference."
  @spec difference_not_found() :: Relay.Error.t()
  def difference_not_found,
    do: Relay.Error.new(:shadow_difference_not_found, "no intentional difference has this id")

  # OP-95
  @doc "Answers the rollout configuration."
  @spec rollout(Relay.Scope.t()) :: answer()
  def rollout(scope) do
    case Relay.Migration.rollout(scope) do
      {:ok, row} -> {:ok, {200, [], rollout_view(row)}}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # OP-53
  # OP-95
  @doc "Replaces the rollout configuration in its own transaction and answers it."
  @spec replace_rollout(Relay.Scope.t(), map(), Relay.Actor.t()) :: answer()
  def replace_rollout(scope, body, actor) do
    case Relay.Migration.replace_rollout(scope, body, actor) do
      {:ok, row} ->
        {:ok, {200, [], rollout_view(row)}}

      {:error, {:ramp, errors}} ->
        {:error,
         Relay.Error.new(:validation_failed, "the rollout step breaks the ramp rule", %{
           errors: errors
         })}

      {:error, :version_conflict} ->
        {:error, Relay.Error.new(:resource_conflict, "the rollout changed since it was read")}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # OP-53
  # OP-95
  @doc "Stops the rollout, opening its incident record, in its own transaction and answers the configuration."
  @spec stop_rollout(Relay.Scope.t(), String.t(), Relay.Actor.t()) :: answer()
  def stop_rollout(scope, reason, actor) do
    case Relay.Migration.stop_rollout(scope, reason, actor) do
      {:ok, row} -> {:ok, {200, [], rollout_view(row)}}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # OP-53
  @doc "Releases the emergency stop in its own transaction and answers the configuration."
  @spec release_rollout(Relay.Scope.t(), String.t(), Relay.Actor.t()) :: answer()
  def release_rollout(scope, reason, actor) do
    case Relay.Migration.release_rollout(scope, reason, actor) do
      {:ok, row} ->
        {:ok, {200, [], rollout_view(row)}}

      {:error, :not_stopped} ->
        {:error, Relay.Error.new(:resource_conflict, "the rollout is not stopped")}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # OP-54
  # OP-95
  @doc "Claims a dedup key for the system being replaced inside the request's scoped transaction."
  @spec claim(Relay.Scope.t(), map()) :: answer()
  def claim(_scope, %{"ttl_seconds" => ttl}) when ttl < @min_ttl_s or ttl > @max_ttl_s do
    {:error,
     Relay.Error.new(:validation_failed, "the claim's time to live is out of bounds", %{
       errors: [%{pointer: "/ttl_seconds", code: "unsupported_value", detail: "out of bounds"}]
     })}
  end

  def claim(scope, %{"key" => key, "ttl_seconds" => ttl}) do
    case Relay.Migration.claim(scope, key, ttl) do
      {:ok, {result, claimed_by, expires_at}} ->
        {:ok,
         {200, [],
          %{
            "object" => "dedup_claim",
            "key" => key,
            "result" => Atom.to_string(result),
            "claimed_by" => claimed_by,
            "expires_at" => expires_at
          }}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # OP-52 (1)
  # OP-94
  @doc "Marks a webhook endpoint as the shadow endpoint or a live one inside the request's scoped transaction."
  @spec set_webhook_shadow(Relay.Scope.t(), Relay.Id.t(), boolean(), Relay.Actor.t()) :: answer()
  def set_webhook_shadow(scope, endpoint_id, shadow, actor) do
    case Relay.Migration.set_webhook_shadow(scope, endpoint_id, shadow, actor) do
      result when result in [:set, :unchanged] ->
        {:ok,
         {200, [],
          %{
            "object" => "webhook_endpoint_shadow",
            "webhook_endpoint_id" => Views.id("whe", endpoint_id),
            "shadow" => shadow
          }}}

      _missing_or_archived ->
        {:error, Relay.Error.new(:webhook_endpoint_not_found, "no webhook endpoint has this id")}
    end
  end

  # OP-54
  # OP-95
  @doc "Counts a subscriber's displayed notification digests; runs outside any transaction."
  @spec displayed(Relay.Scope.t(), Relay.Id.t(), map()) :: answer()
  def displayed(scope, subscriber_id, %{"notifications" => items}) do
    digests = Enum.map(items, & &1["digest"])

    case Relay.Migration.displayed(scope, subscriber_id, digests) do
      {:ok, %{accepted: accepted, duplicates: duplicates}} ->
        {:ok,
         {202, [],
          %{
            "object" => "displayed_notifications",
            "accepted" => accepted,
            "duplicates" => duplicates
          }}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # OP-79
  @doc "The API view of an intentional difference."
  @spec difference_view(map()) :: map()
  def difference_view(row) do
    %{
      "id" => Views.id("sdf", row["id"]),
      "object" => "shadow_difference",
      "layer" => row["layer"],
      "field" => row["field"],
      "template" => row["template_key"],
      "channel" => row["channel"],
      "owner" => row["owner"],
      "reason" => row["reason"],
      "expires_at" => row["expires_at"],
      "renewals" => row["renewals"],
      "state" => if(row["active"], do: "active", else: "expired"),
      "created_at" => row["created_at"],
      "updated_at" => row["updated_at"]
    }
  end

  # OP-95
  @doc "The API view of a rollout configuration; `nil` is the view of a scope without one."
  @spec rollout_view(map() | nil) :: map()
  def rollout_view(nil) do
    %{
      "object" => "rollout",
      "generation" => 0,
      "emergency_stop" => false,
      "stopped_at" => nil,
      "stop_reason" => nil,
      "relay_list" => [],
      "legacy_list" => [],
      "enabled_categories" => [],
      "basis_points" => %{},
      "steps" => %{},
      "updated_at" => nil
    }
  end

  def rollout_view(row) do
    %{
      "object" => "rollout",
      "generation" => row["generation"],
      "emergency_stop" => row["emergency_stop"],
      "stopped_at" => row["stopped_at"],
      "stop_reason" => row["stop_reason"],
      "relay_list" => Enum.map(row["relay_list"], &Base.encode16(&1, case: :lower)),
      "legacy_list" => Enum.map(row["legacy_list"], &Base.encode16(&1, case: :lower)),
      "enabled_categories" => row["enabled_categories"],
      "basis_points" => row["basis_points"],
      "steps" => row["steps"],
      "updated_at" => row["updated_at"]
    }
  end

  defp coverage_view(report) do
    %{
      "object" => "shadow_coverage",
      "window_days" => report.window_days,
      "first_observed_at" => report.first_observed_at,
      "days_observed" => report.days_observed,
      "cycles_met" => report.cycles_met,
      "unexplained_decision_differences" => report.unexplained_decision_differences,
      "active_intentional_differences" => report.active_intentional_differences,
      "exit_criteria_met" => report.exit_criteria_met,
      "rows" => report.rows
    }
  end

  defp location(row), do: {"location", "/v1/shadow/differences/" <> Views.id("sdf", row["id"])}

  defp time(text, pointer) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> {:ok, at}
      _error -> {:error, field_error(pointer, "invalid_format", "RFC 3339")}
    end
  end

  defp time(_text, pointer), do: {:error, field_error(pointer, "required", "required")}

  defp expiry_error,
    do: field_error("/expires_at", "unsupported_value", "at most 30 days ahead and in the future")

  defp field_error(pointer, code, detail) do
    Relay.Error.new(:validation_failed, "the request breaks a field rule", %{
      errors: [%{pointer: pointer, code: code, detail: detail}]
    })
  end

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again")
end
