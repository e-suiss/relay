defmodule Relay.Api.RateLimit do
  @moduledoc """
  The API rate limit (API-49, API-50, API-77): two GCRA tiers per tenant and environment, `burst` and `sustained`, each `weight` per `window_seconds`, decided by the cluster limiter (`Relay.Platform.rate_limit_check/6`, Valkey with the PostgreSQL fallback). An API client can carry a lower sub-limit of its own. The values are the tenant's `api.rate.burst` and `api.rate.sustained` settings; an unset tier takes the contract default (`x-relay-limits.rate_limit`). The most restrictive tier is reported.

  Invalid token attempts and unauthenticated error page reads are limited per client IP in the installation scope, keyed by the SHA-256 of the address so no address is stored (API-47, API-77 (3)).
  """

  @limits Relay.Api.Contract.limits()["rate_limit"]
  @tiers ["burst", "sustained"]
  @per_ip @limits["invalid_token_per_ip"]
  @unavailable "rate_limit.backend_unavailable"

  @type tier :: %{
          name: String.t(),
          quota: pos_integer(),
          window_s: pos_integer(),
          limit: term(),
          parts: [String.t(), ...]
        }
  @type state :: %{
          name: String.t(),
          quota: pos_integer(),
          remaining: non_neg_integer(),
          reset_s: non_neg_integer()
        }
  @type report :: %{tiers: [tier()], current: state() | nil}

  # API-50
  # API-77 (4)
  @doc "The tiers of a tenant from its settings, followed by the API client's sub-limit tiers (`%{id: client_id, tiers: %{\"burst\" => tier}}`) when they are lower."
  @spec tiers(%{optional(String.t()) => map()}, map() | nil) :: [tier(), ...]
  def tiers(settings, client \\ nil) do
    tenant =
      for name <- @tiers do
        value = Map.get(settings, "api.rate." <> name, @limits[name])
        tier(name, "api." <> name, ["all"], value)
      end

    tenant ++ client_tiers(tenant, client)
  end

  defp client_tiers(_tenant, nil), do: []

  defp client_tiers(tenant, %{id: id} = client) do
    for %{name: name} = base <- tenant,
        value = get_in(client, [:tiers, name]),
        is_map(value),
        value["weight"] < base.quota,
        do: tier("client_" <> name, "api.client_" <> name, [id], value)
  end

  defp tier(name, id, parts, %{"weight" => weight, "window_seconds" => window}) do
    %{
      name: name,
      quota: weight,
      window_s: window,
      parts: parts,
      limit:
        limit!(
          id: id,
          algorithm: :gcra,
          unit: :request,
          limit: weight,
          period_ms: window * 1000,
          burst: weight
        )
    }
  end

  # API-49
  # API-50
  # API-51
  # INV-44
  @doc "Spends `cost` on every tier. A denial is `rate_limited` with the longest wait; a limiter that cannot answer is `service_unavailable`, never an unlimited pass."
  @spec check(Relay.Scope.t(), [tier()], non_neg_integer()) ::
          {:ok, report()} | {:error, Relay.Error.t(), report()}
  def check(_scope, tiers, 0), do: {:ok, %{tiers: tiers, current: nil}}

  def check(%Relay.Scope{} = scope, tiers, cost) when is_integer(cost) and cost > 0 do
    results =
      for tier <- tiers,
          do: {tier, Relay.Platform.rate_limit_check(scope, tier.limit, tier.parts, cost, :l1)}

    denied = for {tier, {:deny, retry_ms, rule}} <- results, do: {tier, seconds(retry_ms), rule}

    case denied do
      [] ->
        {:ok, %{tiers: tiers, current: restrictive(results)}}

      _ ->
        {tier, retry_s, _rule} = Enum.max_by(denied, &elem(&1, 1))
        current = %{name: tier.name, quota: tier.quota, remaining: 0, reset_s: retry_s}
        report = %{tiers: tiers, current: current}

        if Enum.any?(denied, fn {_tier, _retry, rule} -> rule == @unavailable end),
          do: {:error, unavailable(retry_s), report},
          else: {:error, limited(tier, retry_s, cost), report}
    end
  end

  # API-47
  # API-77 (3)
  @doc "Spends one attempt of the per-IP limiter `kind` (`:invalid_token` or `:error_pages`) in the installation scope."
  @spec check_ip(Relay.Scope.t(), :invalid_token | :error_pages, :inet.ip_address()) ::
          :ok | {:error, Relay.Error.t()}
  def check_ip(%Relay.Scope{} = installation, kind, ip) do
    limit =
      limit!(
        id: if(kind == :invalid_token, do: "auth.invalid_token", else: "api.error_pages"),
        algorithm: :gcra,
        unit: :request,
        limit: @per_ip["per_minute"],
        period_ms: 60_000,
        burst: @per_ip["burst"]
      )

    address = ip |> :inet.ntoa() |> to_string()
    part = :crypto.hash(:sha256, address) |> Base.encode16(case: :lower)

    case Relay.Platform.rate_limit_check(installation, limit, [part], 1, :l1) do
      {:allow, _info} ->
        :ok

      {:deny, retry_ms, _rule} ->
        tier = %{name: "per_ip", quota: @per_ip["per_minute"]}
        {:error, limited(tier, seconds(retry_ms), 1)}
    end
  end

  defp restrictive(results) do
    states =
      for {tier, {:allow, info}} <- results do
        %{
          name: tier.name,
          quota: tier.quota,
          remaining: Map.get(info, :remaining, tier.quota),
          reset_s: seconds(Map.get(info, :reset_ms, 0))
        }
      end

    Enum.min_by(states, &(&1.remaining / &1.quota), fn -> nil end)
  end

  defp limit!(attrs) do
    {:ok, limit} = Relay.Platform.rate_limit(attrs)
    limit
  end

  defp seconds(ms), do: div(ms + 999, 1000)

  defp limited(tier, retry_s, cost) do
    Relay.Error.new(:rate_limited, "the #{tier.name} rate limit is exceeded", %{
      retry_after: max(retry_s, 1),
      limit: tier.quota,
      actual: cost,
      limit_name: "rate_limit." <> tier.name
    })
  end

  defp unavailable(retry_s) do
    Relay.Error.new(:service_unavailable, "the rate limiter is unavailable", %{
      retry_after: max(retry_s, 1)
    })
  end
end
