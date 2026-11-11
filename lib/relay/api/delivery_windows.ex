defmodule Relay.Api.DeliveryWindows do
  @moduledoc """
  The tenant's DLR windows in the server API (DS-18, DS-50): read the windows in force with the level each comes from, and replace the tenant environment's own windows. A replacement is a new version of the `delivery_windows` data set in the tenant scope, published and activated through `Relay.Datasets` (each step audited, DS-46); an empty list returns to the installation defaults. Windows outside the bounds of `Relay.DeliveryWindows.check/2` are refused with their pointers, never clamped.
  """

  alias Relay.Actor
  alias Relay.Datasets
  alias Relay.DeliveryWindows

  @dataset "delivery_windows"

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # DS-18
  @doc "Reads the windows in force and the tenant's own windows."
  @spec get(Relay.Scope.t()) :: answer()
  def get(scope) do
    with {:ok, installation, tenant} <- versions(scope),
         do: {:ok, {200, [], view(installation, tenant)}}
  end

  # DS-18
  # DS-46
  # DS-50
  @doc "Replaces the tenant's own windows with a new active data set version; outside any transaction."
  @spec replace(Relay.Scope.t(), map(), Actor.t()) :: answer()
  def replace(scope, %{"windows" => rows}, %Actor{} = actor) when is_list(rows) do
    with {:ok, installation, _tenant} <- versions(scope),
         :ok <- check(installation, rows),
         :ok <- publish(scope, rows, actor),
         {:ok, installation, tenant} <- versions(scope) do
      {:ok, {200, [], view(installation, tenant)}}
    end
  end

  defp versions(scope) do
    with {:ok, %{} = installation} <- Datasets.active(Datasets.installation_scope(), @dataset),
         {:ok, tenant} <- Datasets.active(scope, @dataset) do
      {:ok, installation, tenant}
    else
      _missing -> {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  defp check(installation, rows) do
    case DeliveryWindows.check(installation.content, rows) do
      [] ->
        :ok

      errors ->
        details =
          for {index, field, code} <- errors,
              do: %{pointer: "/windows/#{index}/#{field}", code: code, detail: detail(code)}

        {:error, Relay.Error.new(:validation_failed, "windows out of bounds", %{errors: details})}
    end
  end

  defp detail("not_allowed"), do: "outside the bounds of the channel's default window"
  defp detail(_conflict), do: "conflicts with another window"

  defp publish(scope, rows, actor) do
    content = %{"source_ref" => "api", "windows" => rows}

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
    own = if tenant, do: tenant.content["windows"], else: []
    keys = MapSet.new(own, &{&1["channel"], &1["provider"]})

    windows =
      for window <- DeliveryWindows.resolve(installation.content, tenant && tenant.content) do
        own? = MapSet.member?(keys, {window["channel"], window["provider"]})
        Map.put(window, "source", if(own?, do: "tenant", else: "installation"))
      end

    %{
      "object" => "delivery_windows",
      "version" => tenant && tenant.version_no,
      "windows" => windows,
      "tenant_windows" => own
    }
  end
end
