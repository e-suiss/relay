defmodule Relay.Api.ComplianceSettings do
  @moduledoc """
  The tenant's tightening of the compliance table in the server API (PC-40, INV-17): read the tenant environment's own refusals beside the installation's, and replace the tenant's. A replacement is a new version of the `compliance_settings` data set in the tenant scope, published and activated through `Relay.Datasets` (each step audited); an empty list returns to the table as the installation reads it. A refusal names a country or a region of the table and the consent kinds not accepted there; only soft opt-in and legitimate interest can be refused, so the resource can make a row stricter and never looser, and it has no field for a legal send window (PC-47).
  """

  alias Relay.Actor
  alias Relay.Datasets

  @dataset "compliance_settings"

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # PC-40
  @doc "Reads the tenant's refusals and the installation's."
  @spec get(Relay.Scope.t()) :: answer()
  def get(scope) do
    with {:ok, installation, tenant} <- versions(scope),
         do: {:ok, {200, [], view(installation, tenant)}}
  end

  # PC-40
  # INV-17
  @doc "Replaces the tenant's refusals with a new active data set version; outside any transaction."
  @spec replace(Relay.Scope.t(), map(), Actor.t()) :: answer()
  def replace(scope, %{"refusals" => rows}, %Actor{} = actor) when is_list(rows) do
    with :ok <- check(rows),
         :ok <- publish(scope, rows, actor),
         {:ok, installation, tenant} <- versions(scope) do
      {:ok, {200, [], view(installation, tenant)}}
    end
  end

  defp versions(scope) do
    with {:ok, installation} <- Datasets.active(Datasets.installation_scope(), @dataset),
         {:ok, tenant} <- Datasets.active(scope, @dataset) do
      {:ok, installation, tenant}
    else
      _missing -> {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  defp check(rows) do
    case Relay.Compliance.check_refusals(rows) do
      [] ->
        :ok

      errors ->
        details =
          for {index, field, code} <- errors,
              do: %{pointer: "/refusals/#{index}/#{field}", code: code, detail: detail(code)}

        {:error, Relay.Error.new(:validation_failed, "refusals break a rule", %{errors: details})}
    end
  end

  defp detail("not_allowed"), do: "only soft_opt_in and legitimate_interest can be refused"
  defp detail(_conflict), do: "the country is named more than once"

  defp publish(scope, rows, actor) do
    content = %{"source_ref" => "api", "refusals" => rows}

    with {:ok, {result, id, _no}} when result in [:published, :exists] <-
           Datasets.publish(scope, @dataset, content, actor, source_ref: "api"),
         {:ok, activation} when activation in [:activated, :already_active] <-
           Datasets.activate(scope, @dataset, id, :operator, actor) do
      :ok
    else
      {:error, %Relay.Error{code: :validation_failed} = error} -> {:error, error}
      _other -> {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  defp view(installation, tenant) do
    %{
      "object" => "compliance_settings",
      "version" => tenant && tenant.version_no,
      "refusals" => refusals(tenant),
      "installation_refusals" => refusals(installation)
    }
  end

  defp refusals(nil), do: []
  defp refusals(version), do: Map.get(version.content, "refusals", [])
end
