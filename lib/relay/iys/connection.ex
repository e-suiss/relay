defmodule Relay.Iys.Connection do
  @moduledoc """
  What İYS says about a tenant's connection (PC-29, PC-34, E-22).

  `test/3` tries the connection without writing anything: a token, the brands the configuration names (in integrator mode the integrator's authorisations for them) and the subscription.

  `refresh/2` is the scheduled read. In integrator mode the access by type of every configured brand is read from the integrator's authorisation list and recorded with the time it was read; a brand the list does not name has no access. Nothing about an authorisation is assumed: the write path sends only for a brand whose access was read as `write` within the published maximum age. The consent quota (`consentLimit`, `usedConsentLimit`) is read from the subscription: `full` when the limit is reached and may not be exceeded, `warning` from the published percentage of the limit, otherwise `ok`. A change to `warning` or `full` is announced to the tenant as `iys.quota_warning` and counted for the operator. A read that İYS answered also clears the mark of a refused connection.
  """

  require Logger

  alias Relay.Iys
  alias Relay.Iys.Client
  alias Relay.Iys.Store
  alias Relay.Scope

  # PC-29
  # PC-34
  @doc "Tests the connection of a configuration; see the module documentation."
  @spec test(Scope.t(), map(), [map()]) :: map()
  def test(%Scope{} = scope, %{} = config, brands) do
    case Iys.connection(scope, config) do
      {:ok, conn} -> tested(conn, config, brands)
      {:error, _unavailable} -> %{"token" => "credential_unavailable"}
    end
  end

  defp tested(conn, config, brands) do
    case Client.token(conn) do
      {:ok, _token} ->
        %{
          "token" => "ok",
          "brands" => brands_report(conn, config, brands),
          "subscription" => subscription_report(Client.subscription(conn))
        }

      {:error, failure} ->
        %{"token" => reason(failure)}
    end
  end

  defp brands_report(conn, config, brands) do
    configured = Enum.map(brands, & &1["brand_code"])

    case listed(conn, config) do
      {:ok, found} ->
        known = Enum.map(found, & &1.brand_code)
        %{"result" => "ok", "found" => known, "missing" => configured -- known}

      {:error, failure} ->
        %{"result" => reason(failure), "found" => [], "missing" => configured}
    end
  end

  defp listed(conn, %{"mode" => "integrator"}), do: Client.authorisations(conn)
  defp listed(conn, _own), do: Client.brands(conn)

  defp subscription_report({:ok, subscription}) do
    %{
      "result" => "ok",
      "status" => subscription.status,
      "consent_limit" => subscription.consent_limit,
      "used_consent_limit" => subscription.used_consent_limit
    }
  end

  defp subscription_report({:error, failure}), do: %{"result" => reason(failure)}

  defp reason(%{code: code}) when is_binary(code), do: code
  defp reason(%{status: status}) when is_integer(status), do: "http_#{status}"
  defp reason(_transport), do: "unavailable"

  # PC-29
  # PC-34
  @doc "Reads the authorisations and the quota of the scope from İYS and records them; see the module documentation."
  @spec refresh(Scope.t(), DateTime.t()) :: Iys.result(map())
  def refresh(%Scope{} = scope, %DateTime{} = now) do
    with {:ok, %{config: %{} = config}} <- Iys.get_config(scope),
         {:ok, conn} <- Iys.connection(scope, config) do
      authorisations = authorisations(scope, conn, config, now)
      quota = quota(scope, conn, config, now)
      {:ok, %{authorisations: authorisations, quota: quota}}
    else
      {:ok, %{config: nil}} -> {:ok, %{authorisations: :not_configured, quota: :not_configured}}
      {:error, reason} -> {:error, reason}
    end
  end

  # PC-29
  # E-22
  defp authorisations(scope, conn, %{"mode" => "integrator"}, now) do
    case Client.authorisations(conn) do
      {:ok, found} -> authorised(scope, Enum.map(found, &stringified/1), now)
      {:error, failure} -> unread(:authorisations, failure)
    end
  end

  defp authorisations(_scope, _conn, _own, _now), do: :own

  defp authorised(scope, observed, now) do
    case Store.in_scope(scope, fn _status -> Store.brands_observe(observed, now) end) do
      {:ok, result} -> result
      {:error, _reason} -> :unavailable
    end
  end

  defp stringified(entry), do: Map.new(entry, fn {key, value} -> {Atom.to_string(key), value} end)

  # PC-34
  defp quota(scope, conn, config, now) do
    case Client.subscription(conn) do
      {:ok, subscription} -> observed(scope, config, subscription, now)
      {:error, failure} -> unread(:quota, failure)
    end
  end

  defp observed(scope, config, subscription, now) do
    state = state(subscription)

    observation = %{
      "quota_state" => state,
      "consent_limit" => subscription.consent_limit,
      "used_consent_limit" => subscription.used_consent_limit,
      "consent_limit_exceed" => subscription.consent_limit_exceed,
      "blocked_code" => nil
    }

    work = fn _status ->
      previous = Store.config_observe(observation, now)
      if previous != state and state in ["warning", "full"], do: warn(config, observation, now)
      state
    end

    case Store.in_scope(scope, work) do
      {:ok, state} -> state
      {:error, _reason} -> :unavailable
    end
  end

  @doc "The quota state of a subscription: `full`, `warning`, `ok`, or `unknown` when İYS gave no limit."
  @spec state(map()) :: String.t()
  def state(%{consent_limit: limit, used_consent_limit: used} = subscription)
      when is_integer(limit) and is_integer(used) and limit > 0 do
    percent = Iys.limit("quota_warning_percent")

    cond do
      used >= limit and subscription.consent_limit_exceed != true -> "full"
      used * 100 >= limit * percent -> "warning"
      true -> "ok"
    end
  end

  def state(_subscription), do: "unknown"

  defp warn(config, observation, now) do
    data = %{
      "state" => observation["quota_state"],
      "consent_limit" => observation["consent_limit"],
      "used_consent_limit" => observation["used_consent_limit"],
      "observed_at" => now
    }

    meta = %{state: observation["quota_state"]}
    :telemetry.execute([:relay, :iys, :quota], %{count: 1}, meta)
    Store.event("iys.quota_warning", "iys_config:" <> Relay.Id.to_string(config["id"]), data)
  end

  defp unread(what, failure) do
    Logger.warning("an İYS read failed", read: what, code: reason(failure))
    :unavailable
  end
end
