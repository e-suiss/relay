defmodule Relay.Channels.Live do
  @moduledoc """
  The channel step of the delivery job (`Relay.Delivery.Send`, configured as `config :relay, Relay.Delivery, channel: Module`): it hands a rendered delivery to its provider and records the outcome.

    1. The route. On the `test` plane and in `shadow` mode the fake provider answers (X-25, API-62, CH-72); the send mode is the event's own mode (test only), then the tenant's `send_mode.category.<category>.channel.<channel>`, `send_mode.channel.<channel>` and `send_mode` settings for the workflow's category, then the installation default. The route is narrowed to the provider the delivery was accepted with (API-23) and, under the tenant's `channels.domestic_only` policy, to accounts processing data in that country (CH-6, TN-58). Otherwise only a verified provider account whose adapter is activated takes traffic (`Relay.Channels.routes/4`, CH-14, INV-43); without one the delivery is held with `channel.no_route` and the job comes back later. The circuit breakers pick the first account that may be called; a rejection moves to the next account and, when every one is open, the job waits without counting an attempt (CH-13, T-25).
    2. The target. An address channel reads the recipient's active address; a device channel reads the recipient's permitted devices from `Relay.Devices` and takes the most recently seen one of the route's provider platform (CH-28); a recipient whose devices are all without permission is skipped with `channel.no_permission`, one without a device with `channel.no_address`. A target that cannot be read holds the delivery with `channel.target_unavailable`. On the live plane an address in a simulated range is skipped with `channel.invalid_recipient` (CH-72).
    3. The content, from the renderer step's `prepare/2`, which renders the pinned plan again and checks its digest (TP-50). On `push` and `web_push` the push policy is decided from the active `push_priority_map` before the attempt opens (`Relay.Channels.push_policy/2`: platform priority, interruption level, collapse keys, content-free mode and lock screen text; CH-19, CH-23, CH-33, CH-65, CH-67) and handed to the adapter; its recorded reasons (`priority_clamped`, `interruption_clamped`, `critical_not_granted`, `interruption_platform_lowered`, `override_ignored`) are emitted as `[:relay, :push, :policy]`. On SMS and voice the route keeps only the accounts of the message class's traffic, `security` or `standard`, so an OTP never shares an account or a credit pool with a campaign (CH-53), and a `+90` number only the BTK-authorized providers, or the delivery is skipped with `channel.tr_route_unauthorized` (CH-51). Before the attempt `Relay.Channels.sms_preflight/7`, with the renderer's SMS measurement, checks the sender identity's rules for the class (CH-50), the TR route and the explicit encoding (CH-48), and names the provider product (CH-53); a broken rule skips the delivery with its `rule_id`. On WhatsApp, `Relay.Channels.Live.Whatsapp.prepare/4` then applies the number's availability, the customer service window, the template's approval and the tier count (CH-57, CH-58, CH-61).
    4. The provider limits (CH-17): the account, sender and recipient layers of the provider's declared limits, stricter than the provider's and in the channel's unit, each a GCRA decision (`Relay.Channels.Limits`); a denial snoozes the job for its `retry_after` without opening an attempt. A shared account's quota carries the lane ceiling (T-33, TN-53), and a 429 lowers the account's rate until successes raise it again (AIMD, `Relay.Channels.Throttle`); the provider's `Retry-After` still plans the retry.
    5. The attempt. It is opened with the provider idempotency key that stays the same across the logical send (INV-13, OP-6 (4)) and marked started in its own transaction before the call (INV-55, CH-10). The credential is read from the secret backend for this call only, so a rotation applies at the next call (TN-26). The call is bounded by the three timeout layers (CH-9).
    6. The outcome is normalized into the eight failure classes (CH-7). A success finishes the attempt. A failure finishes it and plans its retry through the job queue only (T-26, INV-14); a permanent target failure soft disables the address or the device at once (CH-11); a code without a mapping raises `provider.unknown_code` and the alarm (CH-8). An uncertain outcome follows the provider's declared policy (T-28): the status query, a retry with the same key, or none; on a paid channel at most one retry and `delivery.uncertain`.
  """

  use Boundary,
    top_level?: true,
    deps: [
      Relay,
      Relay.Channels,
      Relay.Delivery,
      Relay.Datasets,
      Relay.Devices,
      Relay.Ingest,
      Relay.Messaging,
      Relay.Platform,
      Relay.Preferences,
      Relay.Secrets,
      Relay.Subscribers,
      Relay.Templates,
      Relay.Tenancy,
      Relay.Webhooks
    ],
    exports: []

  alias Relay.ChannelDeclarations
  alias Relay.Channels.Live.Events
  alias Relay.Channels.Live.Followup
  alias Relay.Channels.Live.Store
  alias Relay.Channels.Live.Whatsapp
  alias Relay.Scope

  @messaging ~w(slack teams telegram discord)
  @phone_channels ~w(sms voice whatsapp)
  @hold_s 300
  @domestic "channels.domestic_only"
  @classes ~w(security transactional action_required operational system social marketing)a
  @call_ms 10_000
  @ranks %{accepted: 1, delivered: 2}

  @type result :: :ok | {:snooze, pos_integer()} | {:error, term()}

  # T-15
  # CH-2
  # CH-14
  # INV-43
  @doc "Runs the channel step of a rendered delivery with the job's arguments; returns as an `Oban.Worker` `perform/1` does."
  @spec deliver(Scope.t(), Relay.Id.t(), map()) :: result()
  def deliver(%Scope{} = scope, delivery_id, args) when is_map(args) do
    with {:ok, %{} = delivery} <- Store.in_scope(scope, fn _ -> Store.delivery(delivery_id) end),
         {:ok, declarations} <- Relay.Datasets.channel_declarations(),
         {:ok, parameters} <- Relay.Datasets.channel_parameters(),
         {:ok, route} <- route(scope, delivery, declarations) do
      ctx = %{
        scope: scope,
        delivery: delivery,
        declarations: declarations,
        parameters: parameters,
        args: args
      }

      admit(ctx, route)
    else
      {:ok, nil} -> :ok
      {:hold, rule_id} -> hold(scope, delivery_id, rule_id)
      {:skip, rule_id} -> skip(scope, delivery_id, rule_id)
      {:error, reason} -> {:error, reason}
    end
  end

  @type usage_price :: {:ok, map()} | :unpriced
  @type usage_pricer :: (... -> usage_price())

  # CH-18
  # OP-38
  @doc "The pricer of the daily usage records over the active provider declarations: a function of provider, channel, destination country, category and the volume already sent in the period that returns the unit price (`Relay.Channels.price/5`) or `:unpriced`; `{:error, reason}` while the declarations cannot be read."
  @spec usage_pricing() :: {:ok, usage_pricer()} | {:error, term()}
  def usage_pricing do
    case Relay.Datasets.channel_declarations() do
      {:ok, declarations} -> {:ok, &usage_price(declarations, &1, &2, &3, &4, &5)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp usage_price(declarations, provider, channel, country, category, volume) do
    case ChannelDeclarations.declaration(declarations, provider) do
      {:ok, declaration} -> Relay.Channels.price(declaration, channel, country, category, volume)
      {:error, :unknown_provider} -> :unpriced
    end
  end

  # CH-60
  @doc "Verifies and applies an inbound WhatsApp Cloud API webhook of a provider account; see `Relay.Channels.Live.Whatsapp.inbound/5`."
  @spec whatsapp_inbound(
          Scope.t(),
          map(),
          Relay.Redacted.t(),
          binary(),
          [{String.t(), String.t()}]
        ) :: {:ok, non_neg_integer()} | {:error, atom()}
  defdelegate whatsapp_inbound(scope, account, app_secret, body, headers),
    to: Whatsapp,
    as: :inbound

  # X-25
  # API-62
  # API-23
  # CH-6
  # TN-58
  defp route(scope, delivery, declarations) do
    settings = settings(scope, delivery)

    if fake?(scope, delivery, settings) do
      {:ok, [%{"id" => nil, "provider" => "fake", "credential_ref_id" => nil}]}
    else
      policy = %{
        draw: :erlang.phash2(delivery["id"]),
        provider: delivery["provider"],
        domestic_country: settings[@domestic]
      }

      result = Relay.Channels.routes(scope, delivery["channel"], declarations, policy)
      routed(result, scope, delivery, declarations)
    end
  end

  defp routed({:ok, {[], _excluded}}, _scope, _delivery, _declarations),
    do: {:hold, "channel.no_route"}

  defp routed({:ok, {accounts, _excluded}}, scope, delivery, declarations) do
    with {:ok, kept} <- traffic(scope, delivery, declarations, accounts),
         do: installation(scope, delivery, kept)
  end

  defp routed({:error, reason}, _scope, _delivery, _declarations), do: {:error, reason}

  # CH-51
  # CH-53
  defp traffic(scope, %{"channel" => channel} = delivery, declarations, accounts)
       when channel in ["sms", "voice"] do
    case Relay.Channels.sms_traffic(accounts, delivery["message_class"]) do
      [] -> {:hold, "channel.no_route"}
      kept when channel == "sms" -> tr_route(scope, delivery, declarations, kept)
      kept -> {:ok, kept}
    end
  end

  defp traffic(_scope, _delivery, _declarations, accounts), do: {:ok, accounts}

  defp tr_route(scope, delivery, declarations, accounts) do
    case address(scope, delivery, %{}) do
      {:ok, value, :address, _id} ->
        number = Relay.Redacted.expose(value)

        case Relay.Channels.tr_route(accounts, number, declarations) do
          [] -> {:skip, "channel.tr_route_unauthorized"}
          kept -> {:ok, kept}
        end

      :unavailable ->
        {:ok, accounts}
    end
  end

  # CH-62
  defp installation(scope, %{"channel" => channel} = delivery, accounts)
       when channel in @messaging do
    case Relay.Messaging.target(scope, delivery["recipient_id"], channel) do
      {:ok, %{account_id: account_id}} ->
        case Enum.filter(accounts, &(&1["id"] == account_id)) do
          [] -> {:hold, "channel.no_route"}
          installed -> {:ok, installed}
        end

      :none ->
        {:hold, "channel.target_unavailable"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp installation(_scope, _delivery, accounts), do: {:ok, accounts}

  defp settings(scope, delivery) do
    keys = [@domestic | Relay.Ingest.send_mode_keys(category(delivery), delivery["channel"])]

    case Store.in_scope(scope, fn _ -> Store.settings(keys) end) do
      {:ok, settings} -> settings
      {:error, _reason} -> %{}
    end
  end

  defp category(delivery), do: delivery["category"] || ""

  # OP-51
  defp fake?(%Scope{environment: :test}, _delivery, _settings), do: true

  defp fake?(_scope, delivery, settings) do
    channel = delivery["channel"]

    installation =
      case Relay.Ingest.installation_send_mode() do
        {:ok, mode} -> mode
        {:error, _reason} -> nil
      end

    mode = delivery["send_mode"]
    Relay.Ingest.send_mode(mode, settings, category(delivery), channel, installation) == :shadow
  end

  # CH-13
  # T-25
  defp admit(ctx, accounts) do
    found =
      Enum.reduce_while(accounts, {:none, nil}, fn account, {_none, wait} ->
        case check(ctx, account) do
          {:go, ticket} -> {:halt, {:go, account, ticket}}
          {:wait, ms} -> {:cont, {:none, min(ms, wait || ms)}}
        end
      end)

    case found do
      {:go, account, ticket} -> target(ctx, account, ticket)
      {:none, wait} -> {:snooze, max(div(wait || 1000, 1000), 1)}
    end
  end

  defp check(_ctx, %{"provider" => "fake"}), do: {:go, nil}

  defp check(ctx, account) do
    target = %{
      tenant_id: ctx.scope.tenant_id,
      environment: ctx.scope.environment,
      channel: ctx.delivery["channel"],
      provider: account["provider"],
      provider_account_id: account["id"]
    }

    case Relay.Channels.check_breaker(ctx.parameters, target) do
      {{:reject, :breaker_open, after_ms, _rule_id}, _ticket} -> {:wait, after_ms}
      {_allowed, ticket} -> {:go, ticket}
    end
  end

  # CH-28
  # CH-72
  defp target(ctx, account, ticket) do
    case read_target(ctx, account) do
      {:ok, value, kind, id} ->
        simulated(ctx, account, ticket, %{kind: kind, id: id, value: value})

      {:ok, %{} = target} ->
        simulated(ctx, account, ticket, target)

      {:skip, rule_id} ->
        skip(ctx.scope, ctx.delivery["id"], rule_id)

      :unavailable ->
        hold(ctx.scope, ctx.delivery["id"], "channel.target_unavailable")
    end
  end

  defp read_target(ctx, account) do
    delivery = ctx.delivery

    case target_kind(delivery) do
      "messaging" -> conversation(ctx.scope, delivery, account)
      "address" -> address(ctx.scope, delivery, account)
      "device" -> device(ctx.scope, delivery, account)
      _endpoint -> fallback(account, :endpoint)
    end
  end

  defp target_kind(%{"channel" => channel}) when channel in @messaging, do: "messaging"
  defp target_kind(delivery), do: delivery["target_kind"]

  defp fallback(%{"provider" => "fake"}, kind), do: {:ok, wrap(""), kind, nil}
  defp fallback(_account, _kind), do: :unavailable

  # CH-62
  defp conversation(scope, delivery, account) do
    case Relay.Messaging.target(scope, delivery["recipient_id"], delivery["channel"]) do
      {:ok, %{id: id, value: value}} -> {:ok, value, :address, id}
      _unavailable -> fallback(account, :address)
    end
  end

  defp address(scope, delivery, account) do
    kind = if delivery["channel"] == "email", do: "email", else: "phone"
    recipient_id = delivery["recipient_id"]

    source = field(scope, recipient_id)

    with {:ok, %{} = row} <- Store.in_scope(scope, fn _ -> Store.address(recipient_id, kind) end),
         {:ok, value} <- Relay.Tenancy.decrypt_field(source, row["address_ct"]) do
      {:ok, value, :address, row["id"]}
    else
      _unreadable -> fallback(account, :address)
    end
  end

  defp field(scope, recipient_id) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: recipient_id,
      retention_class: :recipient_profile,
      table: "recipient_addresses",
      column: "address_ct"
    }
  end

  # CH-28
  # INV-40
  defp device(scope, delivery, account) do
    channel = if delivery["channel"] == "web_push", do: :web_push, else: :push
    recipient_id = delivery["recipient_id"]

    case Relay.Devices.targets(scope, recipient_id, channel, delivery["message_class"]) do
      {:ok, targets} -> platform(targets, account)
      {:skip, reason} -> device_skip(account, reason)
      {:error, _reason} -> fallback(account, :device)
    end
  end

  defp platform(targets, account) do
    fake? = account["provider"] == "fake"

    case Enum.find(targets, &(fake? or &1.platform == account["provider"])) do
      nil -> fallback(account, :device)
      device -> {:ok, %{kind: :device, id: device.id, value: device.token, device: meta(device)}}
    end
  end

  defp meta(device) do
    %{
      platform: device.platform,
      app: device.app,
      apns_environment: device.apns_environment,
      keys: device.keys
    }
  end

  defp device_skip(%{"provider" => "fake"} = account, _reason), do: fallback(account, :device)
  defp device_skip(_account, :no_permission), do: {:skip, "channel.no_permission"}
  defp device_skip(_account, :no_device), do: {:skip, "channel.no_address"}

  defp wrap(value), do: Relay.Redacted.wrap(value)

  # CH-72
  # X-25
  defp simulated(ctx, account, ticket, target) do
    value = Relay.Redacted.expose(target.value)

    if account["provider"] != "fake" and ctx.scope.environment == :live and
         Relay.Channels.simulated_address?(ctx.delivery["channel"], value) do
      skip(ctx.scope, ctx.delivery["id"], "channel.invalid_recipient")
    else
      content(ctx, account, ticket, target)
    end
  end

  # TP-50
  defp content(ctx, account, ticket, target) do
    case renderer().prepare(ctx.scope, ctx.delivery["id"]) do
      {:rendered, content} -> whatsapp(ctx, account, ticket, target, content)
      :rendered -> policy(ctx, account, ticket, target, %{})
      {:error, reason} -> {:error, reason}
      _failed_or_done -> :ok
    end
  end

  # CH-57
  # CH-58
  # CH-61
  defp whatsapp(ctx, %{"provider" => "whatsapp_cloud"} = account, ticket, target, content) do
    to = Relay.Redacted.expose(target.value)

    case Whatsapp.prepare(ctx.scope, account, to, decoded(content)) do
      {:ok, prepared} -> policy(ctx, account, ticket, target, prepared)
      {:skip, rule_id} -> skip(ctx.scope, ctx.delivery["id"], rule_id)
      {:hold, rule_id, _seconds} -> hold(ctx.scope, ctx.delivery["id"], rule_id)
    end
  end

  defp whatsapp(ctx, account, ticket, target, content),
    do: policy(ctx, account, ticket, target, content)

  defp decoded(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{} = map} -> map
      _other -> %{}
    end
  end

  defp decoded(content) when is_map(content), do: content
  defp decoded(_content), do: %{}

  # CH-19
  # CH-23
  # CH-33
  # CH-65
  # CH-67
  defp policy(ctx, account, ticket, target, content) do
    case push_policy(ctx, account, content) do
      {:ok, push} -> preflight(Map.put(ctx, :push, push), account, ticket, target, content)
      {:error, reason} -> {:error, reason}
    end
  end

  defp push_policy(%{delivery: %{"channel" => channel}} = ctx, account, content)
       when channel in ["push", "web_push"] do
    case {priority_table(), account["provider"]} do
      {{:ok, table}, _provider} -> Relay.Channels.push_policy(table, facts(ctx, content))
      {{:error, _reason}, "fake"} -> {:ok, nil}
      {{:error, reason}, _provider} -> {:error, reason}
    end
  end

  defp push_policy(_ctx, _account, _content), do: {:ok, nil}

  # OP-65 (4)
  defp priority_table do
    name = Relay.Channels.push_priority_dataset()

    case Relay.Datasets.active(Relay.Datasets.installation_scope(), name) do
      {:ok, %{content: content, id: id}} -> {:ok, Relay.Channels.push_priority(content, id)}
      {:ok, nil} -> {:error, :push_priority_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp facts(ctx, content) do
    delivery = ctx.delivery
    sensitive = delivery["sensitivity"] == "sensitive"
    content = if is_map(content), do: content, else: %{}

    %{
      tenant_id: ctx.scope.tenant_id,
      delivery_id: Relay.Id.to_string(delivery["id"]),
      message_class: delivery["message_class"],
      priority: delivery["priority"],
      interruption: nil,
      subject_type: delivery["subject_type"],
      subject_id: delivery["subject_id"],
      sensitivity: delivery["sensitivity"],
      category: delivery["category_key"],
      region: Relay.Datasets.installation_region(),
      locale: delivery["locale"],
      lock_screen_body: if(sensitive, do: content["body"]),
      expires_at: delivery["expires_at"],
      now: Relay.Clock.utc_now()
    }
  end

  # CH-48
  # CH-50
  # CH-51
  # CH-53
  defp preflight(ctx, %{"provider" => "fake"} = account, ticket, target, content),
    do: limited(ctx, account, ticket, target, content)

  defp preflight(ctx, account, ticket, target, content) do
    number = Relay.Redacted.expose(target.value)
    %{scope: scope, declarations: declarations, delivery: delivery} = ctx

    measure = &Relay.Templates.sms_measure/3
    found = {number, content, measure}

    case sms_preflight(scope, declarations, account, delivery, found) do
      {:ok, extra} -> limited(Map.put(ctx, :extra, extra), account, ticket, target, content)
      {:skip, rule_id} -> skip(ctx.scope, ctx.delivery["id"], rule_id)
    end
  end

  defp sms_preflight(scope, declarations, account, delivery, {number, content, measure}) do
    Relay.Channels.sms_preflight(scope, declarations, account, delivery, number, content, measure)
  end

  # CH-17
  # T-20
  # T-33
  # TN-53
  defp limited(ctx, account, ticket, target, content) do
    case provider_limits(ctx, account, target, content) do
      :allow -> attempt(ctx, account, ticket, target, content)
      {:deny, ms} -> {:snooze, max(div(ms + 999, 1000), 1)}
    end
  end

  defp provider_limits(_ctx, %{"provider" => "fake"}, _target, _content), do: :allow

  defp provider_limits(ctx, account, target, content) do
    declaration =
      case ChannelDeclarations.declaration(ctx.declarations, account["provider"]) do
        {:ok, declaration} -> declaration
        {:error, _unknown} -> nil
      end

    call = %{
      channel: ctx.delivery["channel"],
      account: account,
      target: Relay.Redacted.expose(target.value),
      content: content,
      factor: Relay.Channels.throttle_factor(account["id"])
    }

    lane = lane(ctx.delivery["message_class"])
    ceiling = Relay.ChannelParameters.lane_ceiling(ctx.parameters, lane)

    declaration
    |> Relay.Channels.limit_checks(call)
    |> Enum.reduce_while(:allow, fn check, :allow ->
      case decide(ctx.scope, check, lane, ceiling) do
        {:allow, _info} -> {:cont, :allow}
        {:deny, ms, _rule_id} -> {:halt, {:deny, ms}}
      end
    end)
  end

  defp decide(scope, check, lane, ceiling) do
    scope = if check.shared, do: Relay.Datasets.installation_scope(), else: scope
    opts = if check.attrs.ceiling, do: [ceiling_bp: ceiling], else: []

    case Relay.Platform.rate_limit(check.attrs) do
      {:ok, limit} ->
        Relay.Platform.rate_limit_check(scope, limit, check.key_parts, check.cost, lane, opts)

      {:error, _invalid} ->
        {:allow, %{}}
    end
  end

  defp lane(class) do
    Enum.find_value(@classes, :l2, fn atom ->
      if Atom.to_string(atom) == class, do: Relay.Platform.lane(atom)
    end)
  end

  # INV-13
  # INV-55
  # OP-6 (4)
  defp attempt(ctx, account, ticket, target, content) do
    %{scope: scope, delivery: delivery} = ctx
    key = Map.get(ctx.args, "provider_idempotency_key") || default_key(delivery["id"])

    open = %{
      id: Relay.Id.generate(),
      delivery_id: delivery["id"],
      provider: account["provider"],
      provider_account_id: account["id"],
      provider_idempotency_key: key
    }

    with {:ok, {:opened, n}} <- Relay.Delivery.open_attempt(scope, open),
         {:ok, :started} <- Relay.Delivery.start_attempt(scope, delivery["id"], n) do
      channel = delivery["channel"]
      _ = Relay.Delivery.count_attempt(scope, ctx.parameters, channel, account["id"], n)
      _ = meter(ctx, n, target)
      call(ctx, account, ticket, request(ctx, account, target, content, key, n))
    else
      {:ok, {:attempt_active, _n}} -> {:snooze, @hold_s}
      {:ok, _not_sendable} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_key(delivery_id), do: "dlv-" <> Relay.Id.to_string(delivery_id)

  # OP-38
  defp meter(ctx, n, target) do
    channel = ctx.delivery["channel"]
    segments = sms_segments(channel, get_in(ctx, [:extra, :segments]))
    country = if channel in @phone_channels, do: Relay.Phone.country(phone(target))

    if country || segments do
      meter = %{destination_country: country, sms_segments: segments}
      Relay.Delivery.meter_attempt(ctx.scope, ctx.delivery["id"], n, meter)
    end
  end

  defp sms_segments("sms", segments) when is_integer(segments) and segments > 0, do: segments
  defp sms_segments(_channel, _segments), do: nil

  defp phone(target) do
    case Relay.Redacted.expose(target.value) do
      value when is_binary(value) -> value
      _other -> ""
    end
  end

  defp request(ctx, account, target, content, key, n) do
    now = Relay.Clock.utc_now()
    expires_at = ctx.delivery["expires_at"]

    timeout =
      case Relay.Channels.call_timeout_ms(expires_at, now, nil, @call_ms) do
        {:ok, ms} -> ms
        :expired -> 1
      end

    ttl =
      case Relay.Channels.ttl_s(expires_at, now) do
        :expired -> 0
        ttl -> ttl
      end

    fields = %{
      scope: ctx.scope,
      delivery_id: ctx.delivery["id"],
      attempt_no: n,
      channel: ctx.delivery["channel"],
      provider: account["provider"],
      idempotency_key: key,
      target: target,
      timeout_ms: timeout,
      content: content,
      credentials: credentials(ctx.scope, account),
      account: account,
      ttl_s: ttl,
      message_class: ctx.delivery["message_class"],
      test?: ctx.scope.environment == :test,
      push: Map.get(ctx, :push),
      update: update(ctx, account, target)
    }

    extra = ctx |> Map.get(:extra, %{}) |> Map.delete(:segments)
    Relay.Channels.request(Map.merge(fields, extra))
  end

  # CH-23
  defp update(ctx, %{"provider" => provider}, %{id: <<_::128>> = target_id})
       when provider in @messaging do
    case Relay.Messaging.update_ref(ctx.scope, target_id, ctx.delivery["id"]) do
      {:ok, {_key, ref}} -> ref
      {:error, _reason} -> nil
    end
  end

  defp update(_ctx, _account, _target), do: nil

  # CH-23
  defp remember(ctx, %{provider: provider, target: %{id: <<_::128>> = id}}, outcome)
       when provider in @messaging do
    delivery_id = ctx.delivery["id"]

    case Relay.Messaging.update_ref(ctx.scope, id, delivery_id) do
      {:ok, {key, _ref}} ->
        _ = Relay.Messaging.remember(ctx.scope, id, key, outcome.provider_message_id, delivery_id)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp remember(_ctx, _request, _outcome), do: :ok

  # TN-26
  defp credentials(_scope, %{"credential_ref_id" => nil}), do: nil

  defp credentials(scope, %{"credential_ref_id" => ref_id}) do
    case Relay.Secrets.fetch(scope, ref_id) do
      {:ok, secret} -> secret
      {:error, _error} -> nil
    end
  end

  # CH-7
  # T-25
  defp call(ctx, account, ticket, request) do
    started = Relay.Clock.monotonic_ms()

    case Relay.Channels.activated_adapter(ctx.declarations, account["provider"]) do
      {:ok, adapter} ->
        result = adapter.deliver(request)
        outcome = normalize(ctx, request, result)
        record_breaker(ticket, outcome, Relay.Clock.monotonic_ms() - started)
        report_policy(request, outcome)
        throttle(account, outcome)
        follow(ctx, adapter, request, outcome)

      {:error, _not_activated} ->
        finish(ctx, request, failed("transient", "transport:adapter_not_activated"), :no_retry)
    end
  end

  # CH-19
  # CH-21
  # CH-65
  # CH-66
  defp report_policy(%{push: %{} = push} = request, outcome) do
    ignored = if outcome.detail[:override_ignored] in [nil, []], do: [], else: [:override_ignored]
    reasons = push.reasons ++ ignored

    if reasons != [] do
      :telemetry.execute([:relay, :push, :policy], %{count: 1}, %{
        tenant_id: request.scope.tenant_id,
        provider: request.provider,
        message_class: push.message_class,
        level: push.level,
        reasons: reasons,
        override_ignored: outcome.detail[:override_ignored] || []
      })
    end

    :ok
  end

  defp report_policy(_request, _outcome), do: :ok

  # DS-10
  defp normalize(ctx, request, result) do
    case Relay.Channels.normalize(ctx.declarations, request.provider, request.channel, result) do
      {:ok, outcome} -> outcome
      {:error, :unknown_event} -> failed("unknown", "evidence:missing")
    end
  end

  defp failed(class, raw_code), do: Relay.Channels.failed_outcome(class, raw_code)

  # CH-17
  defp throttle(%{"id" => nil}, _outcome), do: :ok

  defp throttle(account, %{condition: "rate_limited"}),
    do: Relay.Channels.record_throttle(account["id"], :throttled)

  defp throttle(account, %{state: :succeeded}),
    do: Relay.Channels.record_throttle(account["id"], :success)

  defp throttle(_account, _outcome), do: :ok

  defp record_breaker(nil, _outcome, _latency_ms), do: :ok

  defp record_breaker(ticket, %{state: :succeeded}, latency_ms),
    do: Relay.Channels.record_breaker(ticket, :success, latency_ms)

  defp record_breaker(ticket, outcome, latency_ms) do
    failure = {:failure, outcome.failure_class, outcome.condition}
    Relay.Channels.record_breaker(ticket, failure, latency_ms)
  end

  defp follow(ctx, adapter, request, %{state: :unknown} = outcome),
    do: uncertain(ctx, adapter, request, outcome)

  defp follow(ctx, _adapter, request, outcome), do: finish(ctx, request, outcome, :no_retry)

  # T-28
  # CH-10
  # INV-9
  defp uncertain(ctx, adapter, request, outcome) do
    {:ok, declaration} = ChannelDeclarations.declaration(ctx.declarations, request.provider)
    policy = Map.get(declaration, "provider_idempotency_policy") || %{}
    paid? = ChannelDeclarations.paid?(declaration, request.channel)
    retried? = Map.get(ctx.args, "uncertain_retry") == true

    case Relay.Channels.uncertain(policy, paid?, retried?) do
      :query -> query(ctx, adapter, request, outcome, {paid?, retried?})
      {:retry, mark} -> marked(ctx, request, outcome, :retry, mark)
      {:stop, mark} -> marked(ctx, request, outcome, :no_retry, mark)
    end
  end

  defp query(ctx, adapter, request, outcome, {paid?, retried?}) do
    answer =
      if function_exported?(adapter, :query, 1), do: adapter.query(request), else: :unavailable

    case Relay.Channels.after_query(answer, paid?, retried?) do
      {:outcome, result} -> follow(ctx, adapter, request, normalize(ctx, request, result))
      {:retry, mark} -> marked(ctx, request, outcome, :retry, mark)
      {:stop, mark} -> marked(ctx, request, outcome, :no_retry, mark)
    end
  end

  defp marked(ctx, request, outcome, retry, :uncertain) do
    {:ok, entry} =
      Relay.Delivery.ledger_entry(
        id: Relay.Id.generate(),
        delivery_id: request.delivery_id,
        attempt_no: request.attempt_no,
        actor: :relay,
        event_type: "delivery.uncertain",
        occurred_at: Relay.Clock.utc_now(),
        provider: request.provider,
        raw_code: outcome.raw_code
      )

    _ = Relay.Delivery.append_ledger(ctx.scope, entry)
    finish(ctx, request, outcome, retry)
  end

  defp marked(ctx, request, outcome, retry, :none), do: finish(ctx, request, outcome, retry)

  defp finish(ctx, request, %{state: :succeeded} = outcome, _retry) do
    attrs = %{
      delivery_id: request.delivery_id,
      attempt_no: request.attempt_no,
      state: :succeeded,
      provider_message_id: outcome.provider_message_id,
      event_id: Relay.Id.generate(),
      occurred_at: Relay.Clock.utc_now(),
      delivery_rank: Map.fetch!(@ranks, outcome.delivery_rank),
      traceparent: ctx.delivery["traceparent"]
    }

    case Relay.Delivery.finish_attempt(ctx.scope, attrs) do
      {:ok, _result} ->
        :ok = remember(ctx, request, outcome)
        followups(ctx, request, outcome.followups)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish(ctx, request, outcome, retry) do
    if outcome.unknown_code? do
      _ =
        Relay.Channels.report_unknown_code(
          ctx.scope,
          request.provider,
          request.channel,
          outcome.raw_code
        )
    end

    if Relay.Channels.class_actions(outcome.failure_class).target == :disable,
      do: cleanup(ctx, request, outcome)

    case Relay.Delivery.fail_attempt(ctx.scope, failure(ctx, request, outcome, retry)) do
      {:ok, _plan} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp failure(ctx, request, outcome, retry) do
    account_id = request.account["id"]

    budget =
      case Relay.Delivery.retry_budget(ctx.scope, ctx.parameters, request.channel, account_id) do
        {:ok, decision} -> decision
        {:error, _reason} -> :allow
      end

    retried? =
      Map.get(ctx.args, "uncertain_retry") == true or
        (retry == :retry and outcome.state == :unknown)

    extra = %{"uncertain_retry" => retried?}

    %{
      delivery_id: request.delivery_id,
      attempt_no: request.attempt_no,
      state: outcome.state,
      failure_class: outcome.failure_class,
      raw_code: outcome.raw_code,
      event_id: Relay.Id.generate(),
      occurred_at: Relay.Clock.utc_now(),
      traceparent: ctx.delivery["traceparent"],
      channel: request.channel,
      provider: request.provider,
      condition: outcome.condition,
      message_class: ctx.delivery["message_class"],
      retry_after_ms: outcome.retry_after_ms,
      expires_at: ctx.delivery["expires_at"],
      parameters: ctx.parameters,
      budget: budget,
      uncertain: retry,
      job: &Relay.Delivery.retry_job(ctx.scope, request.delivery_id, &1, extra)
    }
  end

  # CH-11
  # INV-14
  defp cleanup(ctx, request, outcome) do
    delivery = ctx.delivery

    case target_kind(delivery) do
      "messaging" ->
        recipient = delivery["recipient_id"]
        rule_id = "channel.address_disabled"
        _ = Relay.Messaging.disable_target(ctx.scope, recipient, request.channel, rule_id)

      "address" ->
        kind = if request.channel == "email", do: "email", else: "phone"
        recipient = delivery["recipient_id"]
        rule_id = "channel.address_disabled"
        _ = Relay.Channels.disable_address(ctx.scope, recipient, kind, request.channel, rule_id)

      "device" ->
        with id when id != nil <- request.target.id do
          ref = {:device, id}
          Relay.Devices.disable(ctx.scope, ref, :unregistered, failed_at: outcome.timestamp)
        end

      _endpoint ->
        :ok
    end

    :ok
  end

  defp hold(scope, delivery_id, rule_id) do
    until = DateTime.add(Relay.Clock.utc_now(), @hold_s, :second)
    _ = Relay.Delivery.hold(scope, delivery_id, rule_id, until)
    {:snooze, @hold_s}
  end

  defp skip(scope, delivery_id, rule_id) do
    {:ok, entry} =
      Relay.Delivery.ledger_entry(
        id: Relay.Id.generate(),
        delivery_id: delivery_id,
        actor: :relay,
        event_type: "delivery.skipped",
        occurred_at: Relay.Clock.utc_now(),
        failure_kind: :skipped,
        failure_rule_id: rule_id
      )

    case Relay.Delivery.append_ledger(scope, entry) do
      {:ok, _appended} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp renderer do
    :relay
    |> Application.get_env(Relay.Delivery, [])
    |> Keyword.get(:renderer, Relay.Templates.Live)
  end

  # CH-72
  # DS-23
  defp followups(ctx, request, followups) do
    for %{event_code: code, after_ms: ms} <- followups do
      event = %{
        delivery_id: request.delivery_id,
        provider: request.provider,
        channel: request.channel,
        event_code: code
      }

      followup(ctx.scope, event, ms)
    end

    :ok
  end

  defp followup(scope, event, 0), do: Events.record(scope, event)

  defp followup(scope, event, ms) do
    later = DateTime.add(Relay.Clock.business_now(scope), ms, :millisecond)
    Oban.insert(Followup.job(scope, event, Relay.Clock.wall_time(scope, later)))
  end

  # DS-10
  # CH-8
  @doc "Records an event a provider reports after the call; see `Relay.Channels.Live.Events.record/2`. Webhook and receipt handlers call it after verifying the request."
  @spec record_event(Scope.t(), Events.event()) ::
          {:ok, Events.recorded()} | {:error, :unknown_event | :delivery_not_found | term()}
  def record_event(%Scope{} = scope, event), do: Events.record(scope, event)

  # INV-13
  @doc "The delivery of a provider idempotency key that the channel step sent; an adapter correlates the provider's later events with it."
  @spec delivery_of_key(String.t()) :: {:ok, Relay.Id.t()} | :error
  def delivery_of_key("dlv-" <> id) do
    case Relay.Id.parse(id) do
      {:ok, delivery_id} -> {:ok, delivery_id}
      {:error, _reason} -> :error
    end
  end

  def delivery_of_key(_key), do: :error

  # CH-10
  # DS-10
  # CH-8
  @doc "Records a delivery report an adapter read and verified (`c:Relay.Channels.Adapter.reports/3`) through `record_event/2`: the report's correlation is the provider idempotency key of the send, a delivered report is the `delivered` event and a failed one the event code of the provider code's mapping, with the raw code kept. A pending report records nothing; a report without a known key is `{:error, :delivery_not_found}`."
  @spec record_report(Scope.t(), String.t(), map()) ::
          {:ok, Events.recorded() | :pending} | {:error, term()}
  def record_report(%Scope{}, _provider, %{result: :pending}), do: {:ok, :pending}

  def record_report(%Scope{} = scope, provider, %{} = report) do
    with {:ok, delivery_id} <- correlated(report),
         {:ok, declarations} <- Relay.Datasets.channel_declarations() do
      {event_code, raw_code} = event_code(declarations, provider, report.result)

      event = %{
        delivery_id: delivery_id,
        provider: provider,
        channel: report.channel,
        event_code: event_code,
        actor: :provider_webhook,
        raw_code: raw_code,
        occurred_at: Map.get(report, :occurred_at) || Relay.Clock.utc_now(),
        price: get_in(report, [:detail, "price"]),
        detail: Map.get(report, :detail, %{})
      }

      record_event(scope, event)
    end
  end

  defp correlated(report) do
    case delivery_of_key(to_string(Map.get(report, :correlation))) do
      {:ok, delivery_id} -> {:ok, delivery_id}
      :error -> {:error, :delivery_not_found}
    end
  end

  defp event_code(_declarations, _provider, {:delivered, _info}), do: {"delivered", nil}

  defp event_code(declarations, provider, {:rejected, %{code: code}}),
    do: {ChannelDeclarations.expectation(declarations, provider, code)["event_code"], code}
end
