defmodule Relay.Api.Settings do
  @moduledoc """
  The tenant settings of the console (TN-2, OP-19, DS-44, TN-21): the region, which never changes, the default time zone and locale, the last links of the time zone and locale chains, and the retention period of each record class beside the legal period of the tenant's region and sector. The defaults are Relay's own tenant record: Access only seeds them from the tenant's region when the tenant is created, and a change is audited with the tenant record. A tenant's retention period may only extend the legal one, and changing it needs step-up; the operator API checks that before `update/3`.
  """

  alias Relay.Tenancy

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}
  @type written :: {:ok, {200, map()}} | {:partial | :error, Relay.Error.t()}

  @classes ~w(commercial_message commercial_consent delivery_record)

  # TN-2
  # OP-19
  # DS-44
  @doc "Reads the tenant settings of a scope (`getTenantSettings`)."
  @spec get(Relay.Scope.t()) :: answer()
  def get(scope) do
    case read(scope) do
      {:ok, view} -> {:ok, {200, [], view}}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # TN-21
  # OP-19
  @doc "Returns true if a settings change names a retention period, which needs step-up."
  @spec retention_change?(map()) :: boolean()
  def retention_change?(body), do: Map.get(body, "retention", %{}) != %{}

  # TN-2
  # OP-19
  # DS-44
  @doc "Changes the tenant settings of a scope (`updateTenantSettings`) under the tenant record's `version`, the defaults first and then each retention period, each in its own audited write; answers the settings after the change. A failure after a write took effect is `{:partial, error}`."
  @spec update(Relay.Scope.t(), map(), Relay.Actor.t()) :: written()
  def update(scope, body, actor) do
    with {:ok, tenant} <- tenant(scope),
         :ok <- same_version(tenant, body["version"]),
         {:ok, changed} <- defaults(scope, tenant, body, actor),
         :ok <- retention(scope, Map.get(body, "retention", %{}), actor, changed) do
      case read(scope) do
        {:ok, view} -> {:ok, {200, view}}
        {:error, _reason} -> {:partial, unavailable()}
      end
    end
  end

  defp tenant(scope) do
    case Tenancy.tenant(scope) do
      {:ok, %{} = tenant} -> {:ok, tenant}
      _other -> {:error, unavailable()}
    end
  end

  defp same_version(%{"version" => version}, version), do: :ok

  defp same_version(_tenant, _version), do: {:error, conflict()}

  defp conflict,
    do: Relay.Error.new(:resource_conflict, "the settings changed; read them again")

  defp defaults(scope, tenant, body, actor) do
    change = %{
      default_timezone: changed(body["default_timezone"], tenant["default_timezone"]),
      default_locale: changed(body["default_locale"], tenant["default_locale"]),
      sector: tenant["sector"],
      expected_version: tenant["version"],
      record_digest: digest(scope, "tenant.defaults_updated", "tenant")
    }

    if change.default_timezone == nil and change.default_locale == nil do
      {:ok, false}
    else
      write_defaults(scope, change, actor)
    end
  end

  defp changed(nil, _current), do: nil
  defp changed(same, same), do: nil
  defp changed(value, _current), do: value

  defp write_defaults(scope, change, actor) do
    case Tenancy.update_tenant_defaults(scope, change, actor) do
      {:ok, {:updated, _version}} -> {:ok, true}
      {:ok, {:unchanged, _version}} -> {:ok, false}
      {:ok, {:version_conflict, _version}} -> {:error, conflict()}
      {:error, %Relay.Error{code: :invalid_time_zone}} -> field("/default_timezone")
      {:error, %Relay.Error{code: :invalid_locale}} -> field("/default_locale")
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp field(pointer) do
    {:error,
     Relay.Error.new(:validation_failed, "the request breaks a field rule", %{
       errors: [%{pointer: pointer, code: "invalid_format", detail: "not a supported value"}]
     })}
  end

  defp retention(scope, periods, actor, changed) do
    periods
    |> Enum.sort()
    |> Enum.reduce_while({:ok, changed}, fn {class, days}, {:ok, written} ->
      case put_retention(scope, class, days, actor) do
        :ok -> {:cont, {:ok, true}}
        {:error, error} when written -> {:halt, {:partial, error}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, _written} -> :ok
      other -> other
    end
  end

  defp put_retention(scope, class, days, actor) when class in @classes do
    change = %{
      key: "retention." <> class,
      value: days,
      expected_version: nil,
      record_digest: digest(scope, "setting.changed", "retention." <> class)
    }

    case Tenancy.put_setting(scope, change, actor) do
      {:ok, {result, _version}} when result in [:created, :updated, :unchanged, :cleared] ->
        :ok

      {:error, %Relay.Error{code: :retention_shortened, details: %{legal_days: legal}}} ->
        retention_error(class, "a tenant may only extend the legal period of #{legal} days")

      {:error, %Relay.Error{code: :retention_rule_missing}} ->
        retention_error(class, "the class has no legal retention period")

      _other ->
        {:error, unavailable()}
    end
  end

  defp retention_error(class, detail) do
    {:error,
     Relay.Error.new(:validation_failed, detail, %{
       errors: [%{pointer: "/retention/" <> class, code: "not_allowed", detail: detail}]
     })}
  end

  defp read(scope) do
    with {:ok, %{} = tenant} <- Tenancy.tenant(scope),
         {:ok, periods} <- Tenancy.retention_periods(scope) do
      {:ok,
       %{
         "object" => "tenant_settings",
         "region" => to_string(tenant["region"]),
         "default_timezone" => tenant["default_timezone"],
         "default_locale" => tenant["default_locale"],
         "version" => tenant["version"],
         "retention" => Enum.map(periods, &period/1)
       }}
    else
      {:ok, nil} -> {:error, :tenant_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp period(%{class: class, legal_days: legal, days: days}) do
    %{
      "retention_class" => class,
      "legal_days" => legal,
      "days" => days,
      "effective_days" => effective(legal, days)
    }
  end

  defp effective(nil, days), do: days
  defp effective(legal, nil), do: legal
  defp effective(legal, days), do: max(legal, days)

  defp digest(scope, action, ref) do
    environment = Atom.to_string(scope.environment)
    canonical = Relay.Canonical.encode!([action, {:bytes, scope.tenant_id}, environment, ref])
    :crypto.hash(:sha256, canonical)
  end

  defp unavailable,
    do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
