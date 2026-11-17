defmodule Relay.Api.ChannelConsole do
  @moduledoc """
  What the panel shows about channels and providers on the server API (§8.2.2): the status of a provider account (data sent abroad, CH-6; adapter deprecation, CH-4; circuit breaker state, T-25), the sending domain wizard of an e-mail account (CH-36), the e-mail warm-up plans (CH-42) and the cost of a paid channel selection (CH-18, CH-58). Everything here reads; nothing writes.

  A provider account sends data abroad when a processing country of the account, or of its provider's declaration, lies outside the installation region: the region's own country for `tr` and `us`, the European Economic Area for `eu`. Breaker state is node-local. A price the data does not hold is unpriced, never zero; SMS and voice are quoted at the base volume tier, the highest price of a table.
  """

  alias Relay.Api.Views
  alias Relay.ChannelDeclarations
  alias Relay.Channels

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @domestic %{
    "tr" => ~w(TR),
    "us" => ~w(US),
    "eu" => ~w(AT BE BG CY CZ DE DK EE ES FI FR GR HR HU IE IS IT LI LT LU LV MT NL NO PL PT RO
               SE SI SK EU)
  }
  @paid ~w(sms voice whatsapp)
  @route_policy %{draw: 0, provider: nil, domestic_country: nil}

  # CH-4
  # CH-6
  # T-25
  @doc "The status of a provider account of `scope`, outside any transaction."
  @spec status(Relay.Scope.t(), Relay.Id.t()) :: answer()
  def status(scope, id) do
    with {:ok, account} <- account(scope, id),
         {:ok, declarations} <- declarations() do
      declaration =
        case ChannelDeclarations.declaration(declarations, account["provider"]) do
          {:ok, declaration} -> declaration
          {:error, :unknown_provider} -> nil
        end

      breakers = Channels.breaker_states(scope, account)

      {:ok,
       {200, [],
        %{
          "object" => "provider_account_status",
          "provider_account_id" => Views.id("pva", account["id"]),
          "channel" => account["channel"],
          "provider" => account["provider"],
          "data_residency" => residency(account, declaration),
          "adapter" => adapter(declarations, declaration, account["provider"]),
          "circuit_breaker" => %{
            "provider" => Atom.to_string(breakers.provider),
            "account" => Atom.to_string(breakers.account),
            "observed_by" => "node"
          }
        }}}
    end
  end

  # CH-6
  # TN-58
  @doc "The data residency of an account against the installation region: the countries outside it where the account or its provider's declaration processes data."
  @spec residency(map(), map() | nil) :: map()
  def residency(account, declaration) do
    region = Relay.Datasets.installation_region()
    domestic = Map.get(@domestic, region, [])
    own = if account["in_installation"], do: [], else: List.wrap(account["processing_countries"])
    declared = declared_countries(declaration)
    abroad = (own ++ declared) |> Enum.uniq() |> Enum.reject(&(&1 in domestic)) |> Enum.sort()

    %{
      "sends_data_abroad" => abroad != [],
      "reference_region" => region,
      "abroad_countries" => abroad,
      "in_installation" => account["in_installation"],
      "processing_countries" => List.wrap(account["processing_countries"]),
      "declared_processing_countries" => declared,
      "transfer_basis" => account["transfer_basis"],
      "scc_notified_on" => account["scc_notified_on"]
    }
  end

  defp declared_countries(%{"data_residency" => %{"in_installation" => true}}), do: []

  defp declared_countries(%{"data_residency" => %{"processing_countries" => countries}})
       when is_list(countries),
       do: countries |> Enum.uniq() |> Enum.sort()

  defp declared_countries(_declaration), do: []

  defp adapter(_declarations, nil, _provider) do
    %{
      "declared" => false,
      "adapter_version" => nil,
      "activated" => false,
      "deprecation_warning" => false,
      "deprecations" => []
    }
  end

  defp adapter(declarations, declaration, provider) do
    activated =
      declarations
      |> Channels.adapter_status()
      |> Enum.any?(&(&1.provider == provider and &1.activated))

    deprecations = List.wrap(declaration["deprecations"])

    %{
      "declared" => true,
      "adapter_version" => declaration["adapter_version"],
      "activated" => activated,
      "deprecation_warning" => deprecations != [],
      "deprecations" =>
        Enum.map(deprecations, &%{"api" => &1["api"], "sunset_on" => &1["sunset_on"]})
    }
  end

  # CH-36
  # INV-43
  @doc "Runs the sending domain wizard of a provider account of `scope` against live DNS, outside any transaction; an account of another channel has no stream."
  @spec email_domains(Relay.Scope.t(), Relay.Id.t()) :: answer()
  def email_domains(scope, id) do
    with {:ok, account} <- account(scope, id) do
      now = Relay.Clock.utc_now()
      checks = Channels.email_domain_wizard(account, now)
      data = Enum.map(checks, &domain_check(&1, now))
      {:ok, {200, [], %{"object" => "list", "data" => data}}}
    end
  end

  defp domain_check(check, now) do
    result = check.result

    %{
      "object" => "email_domain_check",
      "stream" => check.stream,
      "domain" => check.domain,
      "verified" => result.verified,
      "checked_at" => now,
      "records" =>
        Enum.map(check.records, fn record ->
          %{
            "purpose" => record.purpose,
            "type" => record.type,
            "name" => record.name,
            "value" => record.value
          }
        end),
      "findings" =>
        Enum.map(result.findings, fn finding ->
          %{
            "severity" => Atom.to_string(finding.severity),
            "code" => Atom.to_string(finding.code),
            "subject" => finding.subject
          }
        end),
      "spf" => %{
        "record" => result.spf.record,
        "lookups" => result.spf.lookups,
        "void_lookups" => result.spf.void_lookups
      },
      "dmarc" => dmarc(result.dmarc)
    }
  end

  defp dmarc(nil), do: nil

  defp dmarc(policy),
    do: %{"name" => policy.name, "policy" => policy.policy, "org_domain" => policy.org_domain}

  # CH-42
  @doc "The e-mail warm-up plans of the active `email_warmup_plans` data set, or the bundled plans when no version is active."
  @spec warmup_plans() :: answer()
  def warmup_plans do
    plans = Map.get(dataset("email_warmup_plans", &Channels.email_bundled/1), "plans", [])
    {:ok, {200, [], %{"object" => "list", "data" => Enum.map(plans, &plan/1)}}}
  end

  defp plan(plan) do
    %{
      "id" => plan["id"],
      "applies_to" => plan["applies_to"],
      "until_day" => plan["until_day"],
      "steps" =>
        Enum.map(plan["steps"], fn step ->
          %{
            "from_day" => step["from_day"],
            "daily_cap" => step["daily_cap"],
            "domain_hourly_cap" => step["domain_hourly_cap"],
            "domains" => Map.get(step, "domains", %{})
          }
        end)
    }
  end

  # CH-18
  # CH-58
  @doc "Quotes `quantity` units of a paid channel to `country` (with an optional `category`) for every provider account of the channel in `scope`, routable or not, outside any transaction."
  @spec quote(Relay.Scope.t(), map()) :: answer()
  def quote(scope, query) do
    with {:ok, request} <- quote_request(query),
         {:ok, declarations} <- declarations(),
         {:ok, {usable, excluded}} <- routes(scope, request.channel, declarations) do
      card =
        if request.channel == "whatsapp",
          do: dataset("whatsapp_rate_cards", &Channels.whatsapp_bundled/1)

      rows =
        Enum.map(usable, &{&1["id"], &1["provider"], true}) ++
          Enum.map(excluded, &{&1.id, &1.provider, false})

      {:ok,
       {200, [],
        %{
          "object" => "channel_cost_quote",
          "channel" => request.channel,
          "country" => request.country,
          "category" => request.category,
          "quantity" => request.quantity,
          "data" => Enum.map(rows, &quoted(&1, request, declarations, card))
        }}}
    end
  end

  defp quote_request(query) do
    with {:ok, channel} <- channel(query["channel"]),
         {:ok, country} <- country(query["country"]),
         {:ok, category} <- category(query["category"]),
         {:ok, quantity} <- quantity(query["quantity"]) do
      {:ok, %{channel: channel, country: country, category: category, quantity: quantity}}
    end
  end

  defp channel(channel) when channel in @paid, do: {:ok, channel}
  defp channel(nil), do: field("/query/channel", "required", "sms, voice or whatsapp")
  defp channel(_other), do: field("/query/channel", "invalid_value", "sms, voice or whatsapp")

  defp country(country) when is_binary(country) do
    if country =~ ~r/\A[A-Z]{2}\z/,
      do: {:ok, country},
      else: field("/query/country", "invalid_format", "an ISO 3166-1 alpha-2 code")
  end

  defp country(_missing), do: field("/query/country", "required", "an ISO 3166-1 alpha-2 code")

  defp category(nil), do: {:ok, nil}

  defp category(category) when is_binary(category) do
    if category =~ ~r/\A[a-z][a-z_]{0,31}\z/,
      do: {:ok, category},
      else: field("/query/category", "invalid_format", "a lowercase category name")
  end

  defp category(_other), do: field("/query/category", "invalid_format", "a category name")

  defp quantity(nil), do: {:ok, 1}

  defp quantity(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} when n in 1..10_000_000 -> {:ok, n}
      _other -> field("/query/quantity", "invalid_value", "an integer from 1 to 10000000")
    end
  end

  defp quantity(_other), do: field("/query/quantity", "invalid_value", "an integer")

  defp quoted({id, provider, routable}, request, declarations, card) do
    declaration =
      case ChannelDeclarations.declaration(declarations, provider) do
        {:ok, declaration} -> declaration
        {:error, :unknown_provider} -> nil
      end

    paid = declaration != nil and ChannelDeclarations.paid?(declaration, request.channel)

    request
    |> price(declaration, card)
    |> Map.merge(%{
      "provider_account_id" => Views.id("pva", id),
      "provider" => provider,
      "routable" => routable,
      "paid" => paid
    })
    |> total(request.quantity)
  end

  defp price(%{channel: "whatsapp"} = request, _declaration, card) do
    result =
      if is_map(card) and is_binary(request.category),
        do: Channels.whatsapp_price(card, request.country, request.category),
        else: :unknown

    case result do
      {:ok, micros} ->
        priced("whatsapp_rate_card", card["currency"], "message", micros, nil)

      :unknown ->
        unpriced("whatsapp_rate_card")
    end
  end

  defp price(request, declaration, _card) do
    case Channels.price(declaration, request.channel, request.country, request.category, 0) do
      {:ok, price} ->
        priced(
          "provider_declaration",
          price.currency,
          price.unit,
          price.unit_price_micros,
          price.tier_from
        )

      :unpriced ->
        unpriced("provider_declaration")
    end
  end

  defp priced(source, currency, unit, micros, tier) do
    %{
      "priced" => true,
      "source" => source,
      "currency" => currency,
      "unit" => unit,
      "unit_price_micros" => micros,
      "tier_from" => tier
    }
  end

  defp unpriced(source) do
    %{
      "priced" => false,
      "source" => source,
      "currency" => nil,
      "unit" => nil,
      "unit_price_micros" => nil,
      "tier_from" => nil
    }
  end

  defp total(%{"unit_price_micros" => micros} = row, quantity) when is_integer(micros),
    do: Map.put(row, "total_micros", micros * quantity)

  defp total(row, _quantity), do: Map.put(row, "total_micros", nil)

  defp routes(scope, channel, declarations) do
    case Channels.routes(scope, channel, declarations, @route_policy) do
      {:ok, route} -> {:ok, route}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp account(scope, id) do
    case Channels.get_managed(scope, :account, id) do
      {:ok, %{} = account} -> {:ok, account}
      {:ok, nil} -> {:error, Relay.Error.new(:provider_account_not_found, "no such account")}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp declarations do
    case Relay.Datasets.channel_declarations() do
      {:ok, declarations} -> {:ok, declarations}
      {:error, _error} -> {:error, unavailable()}
    end
  end

  defp dataset(name, bundled) do
    case Relay.Datasets.active(Relay.Datasets.installation_scope(), name) do
      {:ok, %{content: %{} = content}} -> content
      _none -> bundled.(name)
    end
  end

  defp field(pointer, code, detail) do
    {:error,
     Relay.Error.new(:validation_failed, "the query is invalid", %{
       errors: [%{pointer: pointer, code: code, detail: detail}]
     })}
  end

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
