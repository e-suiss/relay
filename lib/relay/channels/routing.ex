defmodule Relay.Channels.Routing do
  @moduledoc """
  The provider route of a delivery on one channel, as a pure function of the channel's provider accounts, their sender identities, the active declarations and the tenant's policy (CH-13, CH-14, INV-43, CH-6, TN-58, API-23).

    * Only a verified route takes traffic: an account that is active and `verified`, whose provider adapter is activated (CH-2) and, on a channel that sends as someone (email, SMS, voice, WhatsApp), with an approved sender identity that is not suspended (C-25, TN-10). An unverified account is listed as such and never used, also while every verified one is failing (CH-14).
    * Under a domestic-only policy an account processing data outside the tenant's country is listed but not routed (CH-6, TN-58).
    * `overrides.<channel>.provider` narrows the route to the verified accounts of that provider; it never widens it (API-23).
    * Active-passive is the default: the primary accounts first, then the backups, each by priority; the circuit breaker moves the call to the next one (CH-13). When every candidate has a weight, the order is weighted: a deterministic draw by the delivery's identifier picks the first account in proportion to the weights and the rest follow as backups (L-56).
  """

  alias Relay.ChannelDeclarations

  @sending ~w(email sms voice whatsapp)

  @type account :: %{required(String.t()) => term()}
  @type policy :: %{
          optional(:domestic_country) => String.t() | nil,
          optional(:provider) => String.t() | nil,
          optional(:draw) => non_neg_integer()
        }
  @type excluded :: %{
          id: Relay.Id.t(),
          provider: String.t(),
          reason: :unverified | :not_activated | :no_sender | :abroad | :not_requested
        }

  # CH-13
  # CH-14
  # INV-43
  # CH-6
  # TN-58
  # API-23
  @doc "Orders the accounts a delivery may use and lists the ones it may not, with the reason. `senders` are the approved, unsuspended sender identities by account identifier; `activated?` says whether a provider's adapter is activated."
  @spec route(
          [account()],
          %{optional(Relay.Id.t()) => [map()]},
          (String.t() -> boolean()),
          ChannelDeclarations.t(),
          policy()
        ) :: {[account()], [excluded()]}
  def route(accounts, senders, activated?, %ChannelDeclarations{} = declarations, policy) do
    {usable, excluded} =
      Enum.reduce(accounts, {[], []}, fn account, {usable, excluded} ->
        case exclusion(account, senders, activated?, declarations, policy) do
          nil -> {[account | usable], excluded}
          reason -> {usable, [excluded(account, reason) | excluded]}
        end
      end)

    {order(Enum.reverse(usable), Map.get(policy, :draw, 0)), Enum.reverse(excluded)}
  end

  defp exclusion(account, senders, activated?, declarations, policy) do
    provider = account["provider"]

    cond do
      account["verification_state"] != "verified" -> :unverified
      not activated?.(provider) -> :not_activated
      not requested?(policy, provider) -> :not_requested
      not domestic?(account, declarations, Map.get(policy, :domestic_country)) -> :abroad
      not sender?(account, senders) -> :no_sender
      true -> nil
    end
  end

  defp requested?(policy, provider) do
    case Map.get(policy, :provider) do
      nil -> true
      requested -> requested == provider
    end
  end

  defp domestic?(_account, _declarations, nil), do: true

  defp domestic?(account, declarations, country) do
    own = account["in_installation"] == true or all_in?(account["processing_countries"], country)

    declared =
      case ChannelDeclarations.declaration(declarations, account["provider"]) do
        {:ok, declaration} -> ChannelDeclarations.domestic?(declaration, country)
        {:error, :unknown_provider} -> false
      end

    own and declared
  end

  defp all_in?([_ | _] = countries, country), do: Enum.all?(countries, &(&1 == country))
  defp all_in?(_countries, _country), do: false

  defp sender?(account, senders) do
    account["channel"] not in @sending or Map.get(senders, account["id"], []) != []
  end

  defp excluded(account, reason),
    do: %{id: account["id"], provider: account["provider"], reason: reason}

  defp order(accounts, draw) do
    if accounts != [] and Enum.all?(accounts, &(&1["weight"] > 0)),
      do: weighted(accounts, draw),
      else: Enum.sort_by(accounts, &{role_rank(&1["role"]), &1["priority"]})
  end

  defp role_rank("primary"), do: 0
  defp role_rank(_backup), do: 1

  # L-56
  defp weighted(accounts, draw) do
    total = accounts |> Enum.map(& &1["weight"]) |> Enum.sum()
    point = rem(draw, total)

    {_sum, first} =
      Enum.reduce_while(accounts, {0, hd(accounts)}, fn account, {sum, _first} ->
        sum = sum + account["weight"]
        if point < sum, do: {:halt, {sum, account}}, else: {:cont, {sum, account}}
      end)

    [first | List.delete(accounts, first)]
  end

  # API-23
  @doc "Returns true when a provider named by `overrides.<channel>.provider` is among the verified, routable accounts of the channel; otherwise the request fails with `channel_not_configured`."
  @spec override_allowed?([account()], String.t()) :: boolean()
  def override_allowed?(routable, provider),
    do: Enum.any?(routable, &(&1["provider"] == provider))

  # API-23
  # C-25
  @doc "Returns true when an `overrides.email.from` address lies on a verified sender identity: an approved, unsuspended `email_domain` equal to its domain or an `email_address` equal to it, compared without case."
  @spec from_allowed?([map()], String.t()) :: boolean()
  def from_allowed?(senders, from) do
    address = String.downcase(from)

    case String.split(address, "@") do
      [_local, domain] -> Enum.any?(senders, &sender_covers?(&1, address, domain))
      _other -> false
    end
  end

  defp sender_covers?(%{"kind" => "email_address", "value" => value}, address, _domain),
    do: String.downcase(value) == address

  defp sender_covers?(%{"kind" => "email_domain", "value" => value}, _address, domain),
    do: String.downcase(value) == domain

  defp sender_covers?(_sender, _address, _domain), do: false

  # API-23
  @doc "The provider a step is narrowed to, by the one-way precedence request > step > workflow > tenant default; each level is a channel-keyed overrides map and the first that names `provider` for the channel wins."
  @spec requested_provider([map() | nil], String.t()) :: String.t() | nil
  def requested_provider(levels, channel) do
    Enum.find_value(levels, fn
      %{^channel => %{"provider" => provider}} when is_binary(provider) -> provider
      _level -> nil
    end)
  end
end
