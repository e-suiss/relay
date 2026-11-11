defmodule Relay.Channels do
  @moduledoc """
  Channel adapters, providers and failover, and the node-local circuit breakers of the providers. Other contexts use only the functions of this module.

  Every adapter implements the common port `Relay.Channels.Adapter` and declares its capabilities, evidence rows, idempotency policy, failure class mapping with test vectors, price and limit data, data residency and inbound verification as versioned data (`Relay.ChannelDeclarations`, CH-2, CH-71); a registered adapter whose declaration is incomplete receives no traffic.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.ChannelDeclarations
  alias Relay.Channels.Adapter
  alias Relay.Channels.Ambiguity
  alias Relay.Channels.Breaker
  alias Relay.Channels.Email.Bounce
  alias Relay.Channels.Email.Event
  alias Relay.Channels.Email.Intake
  alias Relay.Channels.Inbound
  alias Relay.Channels.Limits
  alias Relay.Channels.Outcome
  alias Relay.Channels.Pricing
  alias Relay.Channels.ProviderWebhook
  alias Relay.Channels.Push.CriticalGrant
  alias Relay.Channels.Push.Policy
  alias Relay.Channels.Push.Priority
  alias Relay.Channels.Push.Tokens
  alias Relay.Channels.Registry
  alias Relay.Channels.Request
  alias Relay.Channels.Routing
  alias Relay.Channels.SettingsCheck
  alias Relay.Channels.Simulated
  alias Relay.Channels.Sms
  alias Relay.Channels.SmsSender
  alias Relay.Channels.Store
  alias Relay.Channels.Throttle
  alias Relay.Channels.Timeouts
  alias Relay.Channels.Whatsapp

  require Logger

  @type digest :: <<_::256>>
  @type result(value) :: {:ok, value} | {:error, term()}

  @doc "Supervised children: the owners of the circuit breaker table and the adaptive throttle table, and the holder of the push provider tokens."
  @spec children() :: [Supervisor.child_spec()]
  def children,
    do: [
      Supervisor.child_spec(Breaker, []),
      Supervisor.child_spec(Throttle, []),
      Supervisor.child_spec(Tokens, [])
    ]

  # CH-19
  # OP-65 (4)
  @doc "Builds the `push_priority_map` snapshot from the content of its active version; see `Relay.Channels.Push.Priority.new/2`."
  @spec push_priority(map(), Relay.Id.t()) :: Priority.t()
  defdelegate push_priority(content, version_id), to: Priority, as: :new

  @doc "The name of the push priority data set."
  @spec push_priority_dataset() :: String.t()
  defdelegate push_priority_dataset(), to: Priority, as: :dataset

  # CH-19
  # CH-23
  # CH-33
  # CH-65
  # CH-67
  @doc "Decides the push policy of a delivery; see `Relay.Channels.Push.Policy.decide/2`."
  @spec push_policy(Priority.t(), Policy.facts()) :: {:ok, Policy.t()} | {:error, Relay.Error.t()}
  defdelegate push_policy(table, facts), to: Policy, as: :decide

  # T-25
  # INV-40
  @doc "Asks the provider and tenant breakers whether a call may go; see `Relay.Channels.Breaker.check/3`."
  @spec check_breaker(Relay.ChannelParameters.t(), Breaker.target(), integer()) ::
          {Breaker.decision(), Breaker.ticket()}
  def check_breaker(parameters, target, now \\ Relay.Clock.monotonic_ms()),
    do: Breaker.check(parameters, target, now)

  # T-25
  @doc "Records the outcome of a call the breakers admitted; see `Relay.Channels.Breaker.record/4`."
  @spec record_breaker(Breaker.ticket(), Breaker.outcome(), non_neg_integer() | nil, integer()) ::
          :ok
  def record_breaker(ticket, outcome, latency_ms \\ nil, now \\ Relay.Clock.monotonic_ms()),
    do: Breaker.record(ticket, outcome, latency_ms, now)

  # T-26
  # T-43
  # INV-13
  @doc """
  Sends one provider HTTP request. The client never retries and never follows redirects, whatever the options say: the only retry authority is the job queue (T-26), and a retry is a new job that reuses the attempt's provider idempotency key. TLS certificate verification cannot be turned off (T-43): see `http_options/1`.
  """
  @spec http_request(keyword()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def http_request(opts) when is_list(opts) do
    :ok = Relay.NetworkGuard.check!(:http)
    opts |> http_options() |> Req.request()
  end

  # T-26
  # T-43
  @doc "The options a provider request is sent with: retries and redirects off, and any `:verify` or `:verify_fun` transport option removed, so the peer certificate is always verified."
  @spec http_options(keyword()) :: keyword()
  def http_options(opts) when is_list(opts) do
    opts =
      opts
      |> Keyword.drop([:retry, :max_retries, :retry_delay, :retry_log_level, :redirect])
      |> Keyword.merge(retry: false, redirect: false)

    case Keyword.fetch(opts, :connect_options) do
      {:ok, connect} -> Keyword.put(opts, :connect_options, verified(connect))
      :error -> opts
    end
  end

  defp verified(connect) do
    case Keyword.fetch(connect, :transport_opts) do
      {:ok, transport} ->
        Keyword.put(connect, :transport_opts, Keyword.drop(transport, [:verify, :verify_fun]))

      :error ->
        connect
    end
  end

  # CH-2
  @doc "The registered adapter modules; see `Relay.Channels.Registry`."
  @spec adapters() :: [module(), ...]
  defdelegate adapters(), to: Registry

  # CH-2
  # C-44
  @doc "The activation status of every registered adapter under a declarations snapshot; see `Relay.Channels.Registry.status/1`."
  @spec adapter_status(ChannelDeclarations.t()) :: [Registry.status()]
  defdelegate adapter_status(declarations), to: Registry, as: :status

  # CH-2
  # DS-11
  @doc "The activated adapter of a provider; a registered adapter whose declaration does not pass the gate is `{:error, :not_activated}`."
  @spec activated_adapter(ChannelDeclarations.t(), String.t()) ::
          {:ok, module()} | {:error, :unknown_provider | :not_activated}
  defdelegate activated_adapter(declarations, provider), to: Registry, as: :activated

  # CH-7
  # CH-8
  # DS-10
  @doc "Normalizes an adapter result; see `Relay.Channels.Outcome.normalize/4`."
  @spec normalize(ChannelDeclarations.t(), String.t(), String.t(), Adapter.result()) ::
          {:ok, Outcome.t()} | {:error, :unknown_event}
  defdelegate normalize(declarations, provider, channel, result), to: Outcome

  # CH-7
  # CH-8
  # DS-10
  @doc "Normalizes a delivery report an adapter read; see `Relay.Channels.Outcome.report/4`."
  @spec normalize_report(ChannelDeclarations.t(), String.t(), String.t(), Adapter.report()) ::
          {:ok, Outcome.t() | nil} | {:error, :unknown_event}
  defdelegate normalize_report(declarations, provider, channel, report),
    to: Outcome,
    as: :report

  # CH-7
  @doc "The actions of a failure class; see `Relay.Channels.Outcome.actions/1`."
  @spec class_actions(String.t()) :: Outcome.actions()
  defdelegate class_actions(class), to: Outcome, as: :actions

  # T-28
  # CH-10
  @doc "Decides what follows an uncertain attempt; see `Relay.Channels.Ambiguity.decide/3`."
  @spec uncertain(map(), boolean(), boolean()) :: Ambiguity.decision()
  defdelegate uncertain(policy, paid?, retried?), to: Ambiguity, as: :decide

  # T-28
  @doc "Decides what follows the status query of an uncertain attempt; see `Relay.Channels.Ambiguity.after_query/3`."
  @spec after_query(Ambiguity.query_result(), boolean(), boolean()) ::
          {:outcome, Adapter.result()} | {:retry, Ambiguity.mark()} | {:stop, Ambiguity.mark()}
  defdelegate after_query(result, paid?, retried?), to: Ambiguity

  # CH-9
  # WF-38
  @doc "The channel time to live; see `Relay.Channels.Timeouts.ttl_s/2`."
  @spec ttl_s(DateTime.t() | nil, DateTime.t()) :: pos_integer() | nil | :expired
  defdelegate ttl_s(expires_at, now), to: Timeouts

  # CH-9
  # L-13
  @doc "The timeout of a provider call; see `Relay.Channels.Timeouts.call_ms/4`."
  @spec call_timeout_ms(DateTime.t() | nil, DateTime.t(), pos_integer() | nil, pos_integer()) ::
          {:ok, pos_integer()} | :expired
  defdelegate call_timeout_ms(expires_at, now, channel_ms, provider_ms),
    to: Timeouts,
    as: :call_ms

  # CH-9
  @doc "Parses a provider's `Retry-After`; see `Relay.Channels.Timeouts.retry_after_ms/2`."
  @spec retry_after_ms(String.t() | nil, DateTime.t()) :: non_neg_integer() | nil
  defdelegate retry_after_ms(value, now), to: Timeouts

  # CH-17
  # T-20
  @doc "The provider limit checks of one call; see `Relay.Channels.Limits.checks/2`."
  @spec limit_checks(ChannelDeclarations.declaration() | nil, Limits.call()) :: [Limits.check()]
  defdelegate limit_checks(declaration, call), to: Limits, as: :checks

  # CH-18
  @doc "The unit price of a provider's channel; see `Relay.Channels.Pricing.price/5`."
  @spec price(map() | nil, String.t(), String.t() | nil, String.t() | nil, non_neg_integer()) ::
          {:ok, Pricing.price()} | :unpriced
  defdelegate price(declaration, channel, country, category, volume \\ 0), to: Pricing

  # CH-17
  @doc "The adaptive factor of a provider account's rate; see `Relay.Channels.Throttle.factor/1`."
  @spec throttle_factor(Relay.Id.t() | nil) :: float()
  defdelegate throttle_factor(account_id), to: Throttle, as: :factor

  # CH-17
  @doc "Moves a provider account's adaptive factor after a throttled or successful call; see `Relay.Channels.Throttle.record/2`."
  @spec record_throttle(Relay.Id.t(), :throttled | :success) :: :ok
  defdelegate record_throttle(account_id, outcome), to: Throttle, as: :record

  # CH-72
  # X-26
  @doc "The simulated result table of the fake provider; see `Relay.Channels.Simulated.table/0`."
  @spec simulated_results() :: [%{required(String.t()) => String.t()}, ...]
  defdelegate simulated_results(), to: Simulated, as: :table

  # CH-72
  @doc "The simulated result of an address on a channel."
  @spec simulated_result(String.t(), String.t()) :: Simulated.result()
  def simulated_result(channel, address),
    do: Simulated.result(Simulated.kind(channel), address)

  # CH-72
  # X-25
  @doc "Returns true when an address on a channel lies in a simulated range, which the live plane refuses as `invalid_recipient`."
  @spec simulated_address?(String.t(), String.t()) :: boolean()
  def simulated_address?(channel, address),
    do: Simulated.reserved?(Simulated.kind(channel), address)

  # T-40
  # TN-35
  @doc "Verifies a Standard Webhooks request on its raw body; see `Relay.Channels.Inbound.standard_webhooks/4`."
  @spec verify_standard_webhooks(Inbound.key(), binary(), Inbound.headers(), DateTime.t()) ::
          :ok | {:error, Inbound.reason()}
  defdelegate verify_standard_webhooks(key, body, headers, now),
    to: Inbound,
    as: :standard_webhooks

  # T-40
  @doc "Verifies an HMAC-SHA256 signature of a raw body; see `Relay.Channels.Inbound.hmac/4`."
  @spec verify_hmac(Inbound.key(), binary(), Inbound.headers(), keyword()) ::
          :ok | {:error, Inbound.signature_reason()}
  defdelegate verify_hmac(key, body, headers, opts), to: Inbound, as: :hmac

  # T-40
  @doc "Verifies Twilio's callback signature; see `Relay.Channels.Inbound.hmac_sha1_url/4`."
  @spec verify_twilio(Inbound.key(), String.t(), binary(), Inbound.headers()) ::
          :ok | {:error, Inbound.signature_reason()}
  defdelegate verify_twilio(key, url, body, headers), to: Inbound, as: :hmac_sha1_url

  # CH-3
  @doc "Checks a token carried in a callback URL; see `Relay.Channels.Inbound.url_token/2`."
  @spec verify_url_token(Inbound.key(), String.t() | nil) ::
          :ok | {:error, Inbound.signature_reason()}
  defdelegate verify_url_token(key, given), to: Inbound, as: :url_token

  # T-40
  @doc "Verifies an Ed25519 signature of a raw body; see `Relay.Channels.Inbound.ed25519/4`."
  @spec verify_ed25519(Inbound.key(), binary(), Inbound.headers(), keyword()) ::
          :ok | {:error, Inbound.reason()}
  defdelegate verify_ed25519(key, body, headers, opts), to: Inbound, as: :ed25519

  # CH-39
  # CH-40
  # CH-8
  @doc "Classifies a provider e-mail event against the declarations and the content of the `email_bounce_codes` data set, and plans what it leads to; see `Relay.Channels.Email.Event.classify/3` and `Relay.Channels.Email.Intake.plan/2`."
  @spec email_event_plan(ChannelDeclarations.t(), Event.t(), map()) ::
          {Bounce.t() | nil, [Intake.action()]}
  def email_event_plan(%ChannelDeclarations{} = declarations, event, table) do
    result = Event.classify(event, declarations, table)
    {result, Intake.plan(event, result)}
  end

  # CH-40
  @doc "Decides a soft bounce of an address; see `Relay.Channels.Email.Intake.soft_bounce/3`."
  @spec email_soft_bounce([integer()], integer(), map()) ::
          :count | {:suppress, integer()} | :no_duration
  defdelegate email_soft_bounce(history, now_ms, params),
    to: Intake,
    as: :soft_bounce

  # CH-47
  @doc "Parses a verified e-mail webhook body of `provider` (`postmark`, `sendgrid`, `mailgun` or an SES message) into its events."
  @spec email_events(String.t(), binary() | map() | list()) :: [Event.t()]
  def email_events("postmark", body), do: Relay.Channels.Postmark.events(body)
  def email_events("sendgrid", body), do: Relay.Channels.Sendgrid.events(body)
  def email_events("mailgun", body), do: Relay.Channels.Mailgun.events(body)
  def email_events("ses", body), do: Relay.Channels.Ses.events(body, nil)
  def email_events(_provider, _body), do: []

  # T-40
  @doc "Verifies an ECDSA P-256 signature of a raw body; see `Relay.Channels.Inbound.ecdsa/4`."
  @spec verify_ecdsa(Inbound.key(), binary(), Inbound.headers(), keyword()) ::
          :ok | {:error, Inbound.reason()}
  defdelegate verify_ecdsa(key, body, headers, opts), to: Inbound, as: :ecdsa

  # T-40
  # CH-62
  @doc "Verifies Slack's `v0` request signature of a raw body; see `Relay.Channels.Inbound.slack/4`."
  @spec verify_slack(Inbound.key(), binary(), Inbound.headers(), DateTime.t()) ::
          :ok | {:error, Inbound.reason()}
  defdelegate verify_slack(key, body, headers, now), to: Inbound, as: :slack

  # CH-62
  @doc "Checks a shared secret token in a header; see `Relay.Channels.Inbound.secret_token/3`."
  @spec verify_secret_token(Inbound.key(), Inbound.headers(), String.t()) ::
          :ok | {:error, Inbound.signature_reason()}
  defdelegate verify_secret_token(key, headers, header), to: Inbound, as: :secret_token

  # T-40
  @doc "Verifies a JWT and returns its claims; see `Relay.Channels.Inbound.jwt/3`."
  @spec verify_jwt(Inbound.key(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :bad_signature | :stale_timestamp}
  defdelegate verify_jwt(key, token, opts), to: Inbound, as: :jwt

  # C-45
  # MD-4
  @doc "Creates or changes a provider account in its own scoped transaction; see `Relay.Channels.Store.account_put/3`."
  @spec put_account(Relay.Scope.t(), map(), digest(), Relay.Actor.t()) ::
          result({atom(), pos_integer() | nil})
  def put_account(scope, attrs, digest, actor),
    do: Store.in_scope(scope, fn _status -> Store.account_put(attrs, digest, actor) end)

  # CH-14
  # INV-43
  @doc "Sets the verification state of a provider account; only a verified account receives traffic."
  @spec verify_account(
          Relay.Scope.t(),
          Relay.Id.t(),
          String.t(),
          String.t() | nil,
          digest(),
          Relay.Actor.t()
        ) :: result(atom())
  def verify_account(scope, id, state, rule_id, digest, actor) do
    Store.in_scope(scope, fn _status ->
      Store.account_verify(id, state, rule_id, digest, actor)
    end)
  end

  # TN-26
  # TN-21
  @doc "Points a tenant-owned provider account at a rotated credential; the next provider call reads the new secret without a restart. It needs the step-up record of the change and is audited."
  @spec rotate_credential(
          Relay.Scope.t(),
          Relay.Id.t(),
          Relay.Id.t(),
          String.t() | nil,
          digest(),
          Relay.Actor.t()
        ) :: result(atom())
  def rotate_credential(scope, id, credential_ref_id, step_up_ref, digest, actor) do
    Store.in_scope(scope, fn _status ->
      Store.account_rotate_credential(id, credential_ref_id, step_up_ref, digest, actor)
    end)
  end

  # CH-50
  @doc "Records the SMS type and registration of an SMS sender identity after its rules hold (`Relay.Channels.SmsSender.validate/1`): `{:error, rule_id}` names the broken rule. The registration keeps `iys_brand_code`, `us_brand_id`, `us_campaign_id`, `us_use_case`, `tfv_state` and `brn`."
  @spec register_sms_sender(Relay.Scope.t(), Relay.Id.t(), map(), digest(), Relay.Actor.t()) ::
          result(atom()) | {:error, {:invalid, String.t()}}
  def register_sms_sender(scope, id, %{} = registration, digest, actor) do
    type = registration["sender_type"]
    fields = Map.take(registration, SmsSender.registration_fields())

    result =
      Store.in_scope(scope, fn _status ->
        with {:ok, row} <- Store.sender(id),
             :ok <- SmsSender.validate(SmsSender.identity(row, type, fields)) do
          Store.sender_identity_register(id, type, fields, digest, actor)
        end
      end)

    case result do
      {:ok, {:error, rule_id}} when is_binary(rule_id) -> {:error, {:invalid, rule_id}}
      {:ok, {:error, :not_found}} -> {:ok, :not_found}
      other -> other
    end
  end

  # CH-53
  @doc "Sets the traffic of a provider account, `security` or `standard`; an OTP never shares an account or a credit pool with a campaign."
  @spec set_account_traffic(
          Relay.Scope.t(),
          Relay.Id.t(),
          String.t(),
          digest(),
          Relay.Actor.t()
        ) :: result(atom())
  def set_account_traffic(scope, id, traffic, digest, actor) do
    Store.in_scope(scope, fn _status ->
      Store.account_set_traffic(id, traffic, digest, actor)
    end)
  end

  # CH-50
  # CH-51
  # CH-53
  # CH-48
  @doc """
  The provider-dependent checks of an SMS or voice send on the chosen account, before the attempt opens: the account's approved sender identity; on SMS its rules for the message class (`Relay.Channels.SmsSender.check/2`), the TR route (`Relay.Channels.Sms.route/3`), the explicit encoding with its segments, measured with `measure` (`Relay.Channels.Sms.encoding/4`) and the provider product (`Relay.Channels.Sms.product/2`). Returns the request fields to add, or `{:skip, rule_id}`; other channels pass unchanged.
  """
  @spec sms_preflight(
          Relay.Scope.t(),
          ChannelDeclarations.t(),
          map(),
          map(),
          String.t(),
          map() | binary(),
          Sms.measurer()
        ) :: {:ok, map()} | {:skip, String.t()}
  def sms_preflight(scope, declarations, account, delivery, number, content, measure) do
    if delivery["channel"] in ["sms", "voice"],
      do: preflight(scope, declarations, account, delivery, {number, content, measure}),
      else: {:ok, %{}}
  end

  defp preflight(scope, declarations, account, delivery, {number, content, measure}) do
    with {:ok, sender} <- account_sender(scope, account),
         {:ok, declaration} <- declaration(declarations, account["provider"]) do
      class = delivery["message_class"]

      if delivery["channel"] == "sms",
        do: Sms.preflight(declaration, sender, class, number, content, measure),
        else: {:ok, %{sender: sender}}
    end
  end

  defp account_sender(scope, account) do
    case Store.in_scope(scope, fn _status -> Store.senders([account["id"]]) end) do
      {:ok, [sender | _]} -> {:ok, sender}
      _none -> {:skip, "channel.sender_unapproved"}
    end
  end

  defp declaration(declarations, provider) do
    case ChannelDeclarations.declaration(declarations, provider) do
      {:ok, declaration} -> {:ok, declaration}
      {:error, :unknown_provider} -> {:skip, "channel.sms_encoding_unsupported"}
    end
  end

  # CH-53
  @doc "Keeps the provider accounts of a message class's traffic; see `Relay.Channels.Sms.traffic/2`."
  @spec sms_traffic([map()], String.t() | nil) :: [map()]
  def sms_traffic(accounts, message_class), do: Sms.traffic(accounts, message_class)

  # CH-51
  @doc "Keeps the provider accounts that may send to `number`: for a `+90` number only BTK-authorized providers; see `Relay.Channels.Sms.btk_authorized?/1`."
  @spec tr_route([map()], String.t(), ChannelDeclarations.t()) :: [map()]
  def tr_route(accounts, number, %ChannelDeclarations{} = declarations) do
    if Sms.turkish_number?(number),
      do: Enum.filter(accounts, &btk_route?(declarations, &1)),
      else: accounts
  end

  defp btk_route?(declarations, account) do
    case ChannelDeclarations.declaration(declarations, account["provider"]) do
      {:ok, declaration} -> Sms.btk_authorized?(declaration)
      {:error, :unknown_provider} -> false
    end
  end

  # C-45
  @doc "Records the health of a provider account."
  @spec set_account_health(Relay.Scope.t(), Relay.Id.t(), String.t()) :: result(atom())
  def set_account_health(scope, id, health),
    do: Store.in_scope(scope, fn _status -> Store.account_set_health(id, health) end)

  # C-45
  @doc "A provider account by its identifier, read in its own scoped transaction; `nil` when there is none."
  @spec provider_account(Relay.Scope.t(), Relay.Id.t()) :: result(map() | nil)
  def provider_account(scope, id),
    do: Store.in_scope(scope, fn _status -> Store.account(id) end)

  # CH-14
  # INV-43
  @doc "Marks a provider account whose verification is asked for as `pending`, inside the caller's scoped transaction; a verified account stays verified until its check says otherwise. Answers the account's state before the check."
  @spec request_settings_check(Relay.Id.t(), digest(), Relay.Actor.t()) ::
          :pending | :verified | :not_found
  def request_settings_check(id, digest, actor) do
    case Store.account(id) do
      nil ->
        :not_found

      %{"verification_state" => "verified"} ->
        :verified

      %{} ->
        _ = Store.account_verify(id, "pending", nil, digest, actor)
        :pending
    end
  end

  # CH-52
  @doc "The providers whose adapter has the settings check (`c:Relay.Channels.Adapter.check_settings/1`)."
  @spec settings_check_providers() :: [String.t()]
  def settings_check_providers,
    do: for(a <- Registry.adapters(), SettingsCheck.supported?(a), do: a.provider())

  # CH-14
  # CH-52
  @doc "Runs the settings check of a provider account with its credential within `timeout_ms`; `:unsupported` when its adapter has none."
  @spec check_settings(map(), Relay.Redacted.t() | nil, pos_integer()) ::
          SettingsCheck.outcome()
  def check_settings(%{"provider" => provider} = account, credentials, timeout_ms) do
    with {:ok, adapter} <- Registry.adapter(provider),
         true <- SettingsCheck.supported?(adapter) do
      check = %{account: account, credentials: credentials, timeout_ms: timeout_ms}
      adapter.check_settings(check)
    else
      _unsupported -> :unsupported
    end
  end

  # DS-22
  # DS-48
  @doc "Asks the status endpoint of a request's provider about a sent message for reconciliation (`c:Relay.Channels.Adapter.delivery_status/1`); `:unsupported` when the provider has no registered adapter with a status query."
  @spec reconcile_status(Request.t()) ::
          {:ok, [Adapter.report()]} | :not_received | :unavailable | :unsupported
  def reconcile_status(%Request{provider: provider} = request) do
    case reconciler(provider, :delivery_status) do
      {:ok, adapter} -> adapter.delivery_status(request)
      :unsupported -> :unsupported
    end
  end

  # DS-22
  # DS-48
  @doc "Reads the e-mail events of a provider account between `from` and `to` from its provider's event list API (`c:Relay.Channels.Adapter.report_events/1`) within `timeout_ms`; `:unsupported` when the provider has no registered adapter with one."
  @spec reconcile_events(
          map(),
          Relay.Redacted.t() | nil,
          DateTime.t(),
          DateTime.t(),
          pos_integer()
        ) :: {:ok, [Event.t()]} | :unavailable | :unsupported
  def reconcile_events(%{"provider" => provider} = account, credentials, from, to, timeout_ms) do
    case reconciler(provider, :report_events) do
      {:ok, adapter} ->
        adapter.report_events(%{
          account: account,
          credentials: credentials,
          from: from,
          to: to,
          timeout_ms: timeout_ms
        })

      :unsupported ->
        :unsupported
    end
  end

  defp reconciler(provider, callback) do
    with {:ok, adapter} <- Registry.adapter(provider),
         true <- Code.ensure_loaded?(adapter) and function_exported?(adapter, callback, 1) do
      {:ok, adapter}
    else
      _unsupported -> :unsupported
    end
  end

  # CH-14
  # CH-52
  @doc "What a settings check outcome leads to; see `Relay.Channels.SettingsCheck.plan/3`."
  @spec settings_check_plan(SettingsCheck.mode(), SettingsCheck.outcome(), boolean()) ::
          SettingsCheck.plan()
  defdelegate settings_check_plan(mode, outcome, final?), to: SettingsCheck, as: :plan

  # CH-14
  # CH-52
  # INV-43
  @doc "Applies the plan of a provider account's settings check in one scoped transaction: its verification with its rule, audited under `digest`, its health and, for a mismatch, the `provider_account.settings_mismatched` event."
  @spec apply_settings_check(
          Relay.Scope.t(),
          map(),
          SettingsCheck.plan(),
          digest(),
          Relay.Actor.t()
        ) :: result(atom())
  def apply_settings_check(scope, %{"id" => id} = account, plan, digest, actor) do
    Store.in_scope(scope, fn _status ->
      result = settings_verification(id, plan.verification, digest, actor)
      _ = if plan.health, do: Store.account_set_health(id, plan.health)
      _ = if plan.mismatch, do: Store.settings_mismatched(account, plan.mismatch, plan_rule(plan))
      result
    end)
  end

  defp settings_verification(_id, nil, _digest, _actor), do: :unchanged

  defp settings_verification(id, {state, rule_id}, digest, actor),
    do: Store.account_verify(id, state, rule_id, digest, actor)

  defp plan_rule(%{verification: {_state, rule_id}}), do: rule_id

  # CH-52
  # TN-13 (4)
  @doc "Lists the scopes that have a verified account of `providers` due for its settings check; scopes only, through the discovery escape hatch."
  @spec settings_check_scopes([String.t()], pos_integer(), pos_integer()) ::
          [{Relay.Id.t(), String.t()}]
  defdelegate settings_check_scopes(providers, interval_s, limit), to: Store

  # CH-52
  @doc "The verified accounts of `providers` in a scope whose settings check is due, in their own scoped transaction."
  @spec settings_check_due(Relay.Scope.t(), [String.t()], pos_integer(), pos_integer()) ::
          result([map()])
  def settings_check_due(scope, providers, interval_s, limit) do
    Store.in_scope(scope, fn _status ->
      Store.settings_check_due(providers, interval_s, limit)
    end)
  end

  # C-25
  @doc "Creates or changes a sender identity; see `Relay.Channels.Store.sender_identity_put/3`."
  @spec put_sender_identity(Relay.Scope.t(), map(), digest(), Relay.Actor.t()) ::
          result({atom(), pos_integer() | nil})
  def put_sender_identity(scope, attrs, digest, actor),
    do: Store.in_scope(scope, fn _status -> Store.sender_identity_put(attrs, digest, actor) end)

  # TN-10
  @doc "Suspends a sender identity apart from its tenant, with a rule, or resumes it."
  @spec suspend_sender_identity(
          Relay.Scope.t(),
          Relay.Id.t(),
          boolean(),
          String.t() | nil,
          digest(),
          Relay.Actor.t()
        ) :: result(atom())
  def suspend_sender_identity(scope, id, suspended?, rule_id, digest, actor) do
    Store.in_scope(scope, fn _status ->
      Store.sender_identity_suspend(id, suspended?, rule_id, digest, actor)
    end)
  end

  # C-26
  @doc "Creates or changes a channel identity; see `Relay.Channels.Store.channel_identity_put/3`."
  @spec put_channel_identity(Relay.Scope.t(), map(), digest(), Relay.Actor.t()) ::
          result({atom(), pos_integer() | nil})
  def put_channel_identity(scope, attrs, digest, actor),
    do: Store.in_scope(scope, fn _status -> Store.channel_identity_put(attrs, digest, actor) end)

  @typedoc "A managed channel resource: a provider account, a sender identity or a channel identity."
  @type managed :: :account | :sender | :channel_identity

  # C-25
  # C-26
  # C-45
  @doc "Reads a managed channel resource in its own scoped transaction, or `nil`."
  @spec get_managed(Relay.Scope.t(), managed(), Relay.Id.t()) :: result(map() | nil)
  def get_managed(scope, kind, id),
    do: Store.in_scope(scope, fn _status -> Store.row(kind, id, false) end)

  # API-56
  @doc "Lists managed channel resources newest first from a decoded cursor in their own scoped transaction; at most `limit + 1` rows come back."
  @spec list_managed(Relay.Scope.t(), managed(), map() | nil, pos_integer()) :: result([map()])
  def list_managed(scope, kind, cursor, limit),
    do: Store.in_scope(scope, fn _status -> Store.page(kind, cursor, limit) end)

  @doc "Reads a managed channel resource inside the caller's scoped transaction, or `nil`; `lock: true` holds the row until the transaction ends."
  @spec managed(managed(), Relay.Id.t(), keyword()) :: map() | nil
  def managed(kind, id, opts \\ []), do: Store.row(kind, id, Keyword.get(opts, :lock, false))

  # C-45
  # MD-4
  @doc "Writes a provider account inside the caller's scoped transaction; see `Relay.Channels.Store.account_put/3`."
  @spec write_account(map(), digest(), Relay.Actor.t()) :: {atom(), pos_integer() | nil}
  defdelegate write_account(attrs, digest, actor), to: Store, as: :account_put

  # C-25
  @doc "Writes a sender identity inside the caller's scoped transaction; see `Relay.Channels.Store.sender_identity_put/3`."
  @spec write_sender_identity(map(), digest(), Relay.Actor.t()) :: {atom(), pos_integer() | nil}
  defdelegate write_sender_identity(attrs, digest, actor), to: Store, as: :sender_identity_put

  # C-26
  @doc "Writes a channel identity inside the caller's scoped transaction; see `Relay.Channels.Store.channel_identity_put/3`."
  @spec write_channel_identity(map(), digest(), Relay.Actor.t()) ::
          {atom(), pos_integer() | nil}
  defdelegate write_channel_identity(attrs, digest, actor), to: Store, as: :channel_identity_put

  # C-25
  # C-26
  # C-45
  # OP-73
  @doc "Archives a provider account or a sender identity, or retires a channel identity, inside the caller's scoped transaction; the row stays."
  @spec archive_managed(managed(), Relay.Id.t(), digest(), Relay.Actor.t()) ::
          {atom(), pos_integer() | nil}
  defdelegate archive_managed(kind, id, digest, actor), to: Store, as: :archive

  # C-45
  # OP-73
  @doc "Archives a provider account in its own scoped transaction; it receives no traffic and its row stays."
  @spec archive_account(Relay.Scope.t(), Relay.Id.t(), digest(), Relay.Actor.t()) ::
          result({atom(), pos_integer() | nil})
  def archive_account(scope, id, digest, actor),
    do: Store.in_scope(scope, fn _status -> Store.archive(:account, id, digest, actor) end)

  # C-25
  @doc "Records the review of a sender identity, `pending`, `approved` or `rejected`, in its own scoped transaction; an archived identity is `:archived`."
  @spec review_sender_identity(
          Relay.Scope.t(),
          Relay.Id.t(),
          String.t(),
          digest(),
          Relay.Actor.t()
        ) :: result({atom(), pos_integer() | nil})
  def review_sender_identity(scope, id, approval_state, digest, actor) do
    Store.in_scope(scope, fn _status ->
      case Store.row(:sender, id, true) do
        nil -> {:not_found, nil}
        %{"archived_at" => %DateTime{}} = row -> {:archived, row["version"]}
        row -> Store.sender_identity_put(reviewed(row, approval_state), digest, actor)
      end
    end)
  end

  defp reviewed(row, approval_state) do
    %{
      id: row["id"],
      provider_account_id: row["provider_account_id"],
      subtenant_id: row["subtenant_id"],
      channel: row["channel"],
      kind: row["kind"],
      value: row["value"],
      country: row["country"],
      approval_state: approval_state
    }
  end

  # TN-26 (5)
  @doc "Whether a secret reference is still named by a provider account that is not archived or by an active channel identity, in its own scoped transaction."
  @spec secret_in_use?(Relay.Scope.t(), Relay.Id.t()) :: result(boolean())
  def secret_in_use?(scope, secret_ref_id),
    do: Store.in_scope(scope, fn _status -> Store.secret_in_use?(secret_ref_id) end)

  @doc "Like `secret_in_use?/2`, inside the caller's scoped transaction."
  @spec secret_in_use?(Relay.Id.t()) :: boolean()
  defdelegate secret_in_use?(secret_ref_id), to: Store

  # C-25
  @doc "Whether a provider account already has a sender identity of this kind and value, inside the caller's scoped transaction."
  @spec sender_taken?(Relay.Id.t(), String.t(), String.t()) :: boolean()
  defdelegate sender_taken?(account_id, kind, value), to: Store

  # C-26
  @doc "Whether a channel identity of this kind already has the application reference, inside the caller's scoped transaction."
  @spec app_ref_taken?(String.t(), String.t()) :: boolean()
  defdelegate app_ref_taken?(kind, app_ref), to: Store

  @doc "Like `app_ref_taken?/2`, in its own scoped transaction."
  @spec app_ref_taken?(Relay.Scope.t(), String.t(), String.t()) :: result(boolean())
  def app_ref_taken?(scope, kind, app_ref),
    do: Store.in_scope(scope, fn _status -> Store.app_ref_taken?(kind, app_ref) end)

  # CH-13
  # CH-14
  # INV-43
  @doc "The provider route of a channel in a scope: the usable accounts in order and the excluded ones with their reason; see `Relay.Channels.Routing.route/5`."
  @spec routes(Relay.Scope.t(), String.t(), ChannelDeclarations.t(), Routing.policy()) ::
          result({[Routing.account()], [Routing.excluded()]})
  def routes(scope, channel, %ChannelDeclarations{} = declarations, policy) do
    Store.in_scope(scope, fn _status ->
      {route, _senders} = route_here(channel, declarations, policy)
      route
    end)
  end

  # API-23
  # CH-14
  # CH-6
  @doc "Checks the channel overrides of a send request against the verified routes of the scope: `overrides.<channel>.provider` names a provider with a verified, routable account of that channel, and every `overrides.email.from` the e-mail steps send with lies on a verified sender domain or address of a routable email account. Returns the first failing channel and field."
  @spec check_overrides(
          Relay.Scope.t(),
          [{String.t(), String.t()}],
          [String.t()],
          ChannelDeclarations.t(),
          Routing.policy()
        ) :: result(:ok | {:not_configured, String.t(), :provider | :from})
  def check_overrides(scope, providers, froms, %ChannelDeclarations{} = declarations, policy) do
    Store.in_scope(scope, fn _status ->
      missing =
        Enum.find(providers, fn {channel, provider} ->
          {{usable, _excluded}, _senders} =
            route_here(channel, declarations, Map.put(policy, :provider, provider))

          not Routing.override_allowed?(usable, provider)
        end)

      case {missing, froms} do
        {{channel, _provider}, _froms} -> {:not_configured, channel, :provider}
        {nil, []} -> :ok
        {nil, froms} -> from_check(froms, declarations, policy)
      end
    end)
  end

  defp from_check(froms, declarations, policy) do
    {{usable, _excluded}, senders} = route_here("email", declarations, policy)

    ids = MapSet.new(usable, & &1["id"])
    own = Enum.filter(senders, &MapSet.member?(ids, &1["provider_account_id"]))

    if Enum.all?(froms, &Routing.from_allowed?(own, &1)),
      do: :ok,
      else: {:not_configured, "email", :from}
  end

  # API-23
  # C-25
  @doc "Returns true when an `overrides.email.from` address lies on a verified sender identity of the provider account the route chose, checked again at send time; see `Relay.Channels.Routing.from_allowed?/2`."
  @spec from_allowed?(Relay.Scope.t(), Relay.Id.t(), String.t()) :: result(boolean())
  def from_allowed?(scope, account_id, from) do
    Store.in_scope(scope, fn _status ->
      account_id |> List.wrap() |> Store.senders() |> Routing.from_allowed?(from)
    end)
  end

  # API-23
  @doc "The channel block a send uses; see `Relay.Channels.Routing.effective_override/2`."
  @spec effective_override([map() | nil], String.t()) :: map()
  defdelegate effective_override(levels, channel), to: Routing

  # API-23
  @doc "The provider a step is narrowed to; see `Relay.Channels.Routing.requested_provider/2`."
  @spec requested_provider([map() | nil], String.t()) :: String.t() | nil
  defdelegate requested_provider(levels, channel), to: Routing

  defp route_here(channel, declarations, policy) do
    accounts = Store.accounts(channel)
    senders = Store.senders(Enum.map(accounts, & &1["id"]))
    grouped = Enum.group_by(senders, & &1["provider_account_id"])
    activated? = &match?({:ok, _adapter}, Registry.activated(declarations, &1))
    {Routing.route(accounts, grouped, activated?, declarations, policy), senders}
  end

  # CH-11
  # INV-14
  @doc "Soft disables a recipient's active address of `kind` (`email` or `phone`) after a permanent target failure and announces `address.disabled`, in its own scoped transaction."
  @spec disable_address(Relay.Scope.t(), Relay.Id.t(), String.t(), String.t(), String.t()) ::
          result({:disabled | :not_found, Relay.Id.t() | nil})
  def disable_address(scope, recipient_id, kind, channel, rule_id) do
    Store.in_scope(scope, fn _status ->
      Store.address_disable(recipient_id, kind, channel, rule_id)
    end)
  end

  # CH-8
  # INV-46
  @doc "Reports a provider code without a mapping: the `provider.unknown_code` event, `[:relay, :channels, :unknown_code]` telemetry and an error log that alarms the operator; the code is classified `unknown`, never guessed."
  @spec report_unknown_code(Relay.Scope.t(), String.t(), String.t(), String.t()) ::
          result(:appended)
  def report_unknown_code(scope, provider, channel, raw_code) do
    meta = %{provider: provider, channel: channel}
    :telemetry.execute([:relay, :channels, :unknown_code], %{count: 1}, meta)

    Logger.error("a provider code has no mapping; classified unknown",
      provider: provider,
      channel: channel
    )

    Store.in_scope(scope, fn _status -> Store.unknown_code(provider, channel, raw_code) end)
  end

  # CH-66
  @doc """
  Asks Access for the recipient's Grant of critical interruption to a sender (`Relay.Channels.Push.CriticalGrant.decide/2`): `:permit` only on an explicit permit, otherwise `:deny` or `:unavailable`, and the caller delivers at the class ceiling with `critical_not_granted`. The implementation is `config :relay, Relay.Channels, critical_grant: module`, `Relay.Channels.Push.AccessGrant` by default.
  """
  @spec critical_grant(CriticalGrant.query()) :: CriticalGrant.decision()
  def critical_grant(%{} = query) do
    module =
      :relay
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:critical_grant, Relay.Channels.Push.AccessGrant)

    CriticalGrant.decide(module, query)
  end

  # CH-2
  @doc "Builds the request of one provider call; see `Relay.Channels.Request`."
  @spec request(map()) :: Request.t()
  def request(%{} = fields), do: struct!(Request, fields)

  # CH-7
  @doc "A failed outcome of a class with a raw code, for a call Relay could not make or classify; a `transient` one has the `server_error` condition."
  @spec failed_outcome(String.t(), String.t()) :: Outcome.t()
  def failed_outcome(class, raw_code) when is_binary(class) and is_binary(raw_code) do
    condition = if class == "transient", do: "server_error"

    %Outcome{
      state: :failed,
      event_code: "rejected",
      failure_class: class,
      condition: condition,
      raw_code: raw_code
    }
  end

  # CH-60
  # TN-13 (4)
  @doc "The active WhatsApp Cloud API provider account of an inbound webhook's path and the scope it belongs to; `:not_found` for an unknown, other or disabled account or an inactive tenant."
  @spec whatsapp_inbound_account(Relay.Id.t()) :: {:ok, Relay.Scope.t(), map()} | :not_found
  def whatsapp_inbound_account(id) do
    case Store.account_resolve(id) do
      %{"provider" => "whatsapp_cloud", "channel" => "whatsapp", "state" => "active"} = row ->
        inbound_account(id, row)

      _other ->
        :not_found
    end
  end

  # WH-49
  # TN-13 (4)
  @doc "The active provider account of an SMS or e-mail provider webhook's path (`Relay.Channels.ProviderWebhook.providers/0`) and the scope it belongs to; `:not_found` for an unknown, other or disabled account or an inactive tenant."
  @spec provider_webhook_account(Relay.Id.t()) :: {:ok, Relay.Scope.t(), map()} | :not_found
  def provider_webhook_account(id) do
    providers = ProviderWebhook.providers()

    case Store.account_resolve(id) do
      %{"provider" => provider, "state" => "active"} = row ->
        if provider in providers, do: inbound_account(id, row), else: :not_found

      _other ->
        :not_found
    end
  end

  @type webhook_request :: ProviderWebhook.request()
  @type webhook_item :: ProviderWebhook.item()
  @type webhook_reason :: ProviderWebhook.reason()

  # WH-49
  # T-40
  @doc "Verifies an SMS or e-mail provider webhook on its raw body and reads its items; see `Relay.Channels.ProviderWebhook.read/3`."
  @spec provider_webhook(String.t(), Relay.Redacted.t(), webhook_request()) ::
          {:ok, [webhook_item()]} | {:error, webhook_reason()}
  defdelegate provider_webhook(provider, key, request), to: ProviderWebhook, as: :read

  # CH-47
  @doc "Builds an e-mail event (`Relay.Channels.Email.Event`) from its fields, such as one read back from a sealed receipt."
  @spec email_event(map()) :: Event.t()
  def email_event(%{} = fields), do: struct!(Event, fields)

  defp inbound_account(id, %{"tenant_status" => "active"} = row) do
    case Relay.Environment.cast(row["environment"]) do
      {:ok, environment} ->
        scope = Relay.Scope.new!(row["tenant_id"], environment)
        {:ok, scope, %{"id" => id, "provider" => row["provider"], "settings" => row["settings"]}}

      _invalid ->
        :not_found
    end
  end

  defp inbound_account(_id, _row), do: :not_found

  # CH-60
  # T-40
  @doc "Verifies a WhatsApp Cloud API webhook on its raw body with the app secret and parses it into items; see `Relay.Channels.Whatsapp.Webhook`."
  @spec whatsapp_webhook(Relay.Redacted.t(), binary(), Inbound.headers()) ::
          {:ok, [Whatsapp.Webhook.item()]}
          | {:error, :missing_header | :bad_signature | :invalid_body}
  def whatsapp_webhook(app_secret, body, headers) do
    with :ok <- Whatsapp.Webhook.verify(app_secret, body, headers),
         do: Whatsapp.Webhook.parse(body)
  end

  @doc "Answers Meta's webhook subscription check; see `Relay.Channels.Whatsapp.Webhook.challenge/2`."
  @spec whatsapp_challenge(map(), Relay.Redacted.t()) :: {:ok, String.t()} | :error
  defdelegate whatsapp_challenge(params, verify_token), to: Whatsapp.Webhook, as: :challenge

  # CH-58
  @doc "Whether the customer service window of a recipient is open at `now`, from the time of the recipient's last inbound message; see `Relay.Channels.Whatsapp.Window`."
  @spec whatsapp_window_open?(DateTime.t() | nil, DateTime.t()) :: boolean()
  def whatsapp_window_open?(nil, _now), do: false

  def whatsapp_window_open?(%DateTime{} = last, now),
    do: Whatsapp.Window.open?(%{last_inbound_at: last}, now)

  @doc "The length of the customer service window in milliseconds."
  @spec whatsapp_window_ms() :: pos_integer()
  defdelegate whatsapp_window_ms(), to: Whatsapp.Window, as: :window_ms

  # CH-58
  @doc "Chooses the message kind of a WhatsApp content in an open or closed window and returns the content with its `kind`; see `Relay.Channels.Whatsapp.Window.choose/2`."
  @spec whatsapp_choose(boolean(), map()) ::
          {:ok, map(), Whatsapp.Message.kind()} | {:error, :window_closed | :no_content}
  def whatsapp_choose(open?, content) when is_map(content) do
    with {:ok, kind} <- Whatsapp.Window.choose(open?, Whatsapp.Message.kinds(content)),
         do: {:ok, Map.put(content, "kind", Atom.to_string(kind)), kind}
  end

  # CH-57
  # TP-23
  @doc "Whether the template a WhatsApp content names may be sent on a provider account: `:ok` only for a registered, approved template; otherwise the template's state or `:not_registered`."
  @spec whatsapp_template_sendable(Relay.Scope.t(), Relay.Id.t(), map()) ::
          :ok | {:error, String.t() | :not_registered | :invalid_content} | {:error, term()}
  def whatsapp_template_sendable(scope, account_id, content) when is_map(content) do
    with {:ok, language} <- Whatsapp.Message.language(content["language"]),
         {:ok, row} <-
           Whatsapp.Store.in_scope(scope, fn _status ->
             Whatsapp.Store.find(account_id, content["template_name"], language)
           end) do
      case row do
        nil -> {:error, :not_registered}
        %{"status" => status} -> sendable(status)
      end
    end
  end

  defp sendable(status) do
    if Whatsapp.Template.sendable?(status), do: :ok, else: {:error, status}
  end

  # CH-57
  # TP-23
  @doc "The row a WhatsApp template is registered with: its Meta name and language, its Relay class mapped to its fixed category, its components and their digest."
  @spec whatsapp_template_row(map()) :: {:ok, map()} | {:error, :unknown_class | :invalid_content}
  def whatsapp_template_row(attrs) do
    with {:ok, category} <- Whatsapp.Template.category(attrs.message_class),
         {:ok, language} <- Whatsapp.Message.language(attrs.language) do
      {:ok,
       Map.merge(attrs, %{
         id: Relay.Id.generate(),
         language: language,
         category: category,
         content_digest: Whatsapp.Template.digest(attrs.components)
       })}
    end
  end

  # CH-57
  @doc "Registers a WhatsApp template row inside the caller's scoped transaction; it starts `pending_approval`. The same name and language with other content is `:content_conflict`."
  @spec insert_whatsapp_template(map()) ::
          {:created | :exists | :content_conflict | :account_not_found, Relay.Id.t() | nil}
  defdelegate insert_whatsapp_template(row), to: Whatsapp.Store, as: :register

  @doc "Reads a WhatsApp template inside the caller's scoped transaction, or `nil`."
  @spec whatsapp_template(Relay.Id.t()) :: map() | nil
  defdelegate whatsapp_template(id), to: Whatsapp.Store, as: :get

  # API-56
  @doc "Lists WhatsApp templates newest first from a decoded cursor in their own scoped transaction; at most `limit + 1` rows come back."
  @spec whatsapp_templates(Relay.Scope.t(), map() | nil, pos_integer()) :: result([map()])
  def whatsapp_templates(scope, cursor, limit),
    do: Whatsapp.Store.in_scope(scope, fn _status -> Whatsapp.Store.list(cursor, limit) end)

  @doc "Reads a WhatsApp template in its own scoped transaction, or `nil`."
  @spec get_whatsapp_template(Relay.Scope.t(), Relay.Id.t()) :: result(map() | nil)
  def get_whatsapp_template(scope, id),
    do: Whatsapp.Store.in_scope(scope, fn _status -> Whatsapp.Store.get(id) end)

  # TP-23
  @doc "The view of a WhatsApp template row: the Meta-approved text with the cell's parameters in place and whether it diverges, and the edits left under `limits`."
  @spec whatsapp_template_view(map(), [map()], map(), DateTime.t()) :: map()
  def whatsapp_template_view(row, parameters, limits, now) do
    approved = row["approved_components"] || []

    %{
      preview: Whatsapp.Template.preview(approved, parameters),
      edit_quota: Whatsapp.Template.edit_quota(row["edits"] || [], limits, now),
      drift: Whatsapp.Template.drift(row["category"], row["meta_category"]),
      sendable: Whatsapp.Template.sendable?(row["status"])
    }
  end

  # TP-23
  # CH-57
  @doc "Applies a template change of a WhatsApp webhook to the template of a provider account in its own scoped transaction: a Meta status moves the Relay state (`Relay.Channels.Whatsapp.Template.transition/2`), a category change is recorded and a drift announced, an edit is counted."
  @spec whatsapp_template_change(Relay.Scope.t(), Relay.Id.t(), Whatsapp.Webhook.item()) ::
          result(atom())
  def whatsapp_template_change(scope, account_id, {:template_status, change}) do
    Whatsapp.Store.in_scope(scope, fn _status ->
      case Whatsapp.Store.find(account_id, change.name || "", change.language || "") do
        nil ->
          :not_found

        row ->
          {result, _id, _previous} =
            Whatsapp.Store.status(%{
              provider_account_id: account_id,
              name: row["name"],
              language: row["language"],
              meta_template_id: change.template_id,
              meta_status: change.event,
              status: Whatsapp.Template.transition(row["status"], change.event),
              reason: change.reason,
              expected_version: row["version"]
            })

          result
      end
    end)
  end

  def whatsapp_template_change(scope, account_id, {:template_category, change}) do
    Whatsapp.Store.in_scope(scope, fn _status ->
      if change.new_category in Whatsapp.Template.categories() and is_binary(change.name) and
           is_binary(change.language) do
        account_id
        |> Whatsapp.Store.category(change.name, change.language, change.new_category)
        |> elem(0)
      else
        :ignored
      end
    end)
  end

  def whatsapp_template_change(scope, account_id, {:template_edit, change}) do
    Whatsapp.Store.in_scope(scope, fn _status ->
      if is_binary(change.name) and is_binary(change.language) do
        components = if change.components == [], do: nil, else: change.components
        at = Relay.Clock.utc_now()

        account_id
        |> Whatsapp.Store.edit(change.name, change.language, components, at)
        |> elem(0)
      else
        :ignored
      end
    end)
  end

  def whatsapp_template_change(_scope, _account_id, _item), do: {:ok, :ignored}

  # CH-57
  # CH-61
  @doc "Appends a WhatsApp tenant event in its own scoped transaction."
  @spec whatsapp_event(Relay.Scope.t(), String.t(), String.t(), map()) :: result(:appended)
  def whatsapp_event(scope, type, stream_key, data) do
    Whatsapp.Store.in_scope(scope, fn _status -> Whatsapp.Store.event(type, stream_key, data) end)
  end

  # CH-59
  @doc "The follow-up a WhatsApp error code calls for; see `Relay.Channels.Whatsapp.Errors.follow_up/1`."
  @spec whatsapp_follow_up(String.t() | nil) :: Whatsapp.Errors.follow_up()
  defdelegate whatsapp_follow_up(code), to: Whatsapp.Errors, as: :follow_up

  # CH-61
  @doc "The recipient limit of a tier; see `Relay.Channels.Whatsapp.Limits.tier_limit/2`."
  @spec whatsapp_tier_limit(map(), String.t() | nil) :: Whatsapp.Limits.tier_limit()
  defdelegate whatsapp_tier_limit(limits, tier), to: Whatsapp.Limits, as: :tier_limit

  # CH-61
  @doc "Whether a tier count crosses the warning share; see `Relay.Channels.Whatsapp.Limits.warn?/4`."
  @spec whatsapp_tier_warn?(
          map(),
          non_neg_integer(),
          non_neg_integer(),
          Whatsapp.Limits.tier_limit()
        ) :: boolean()
  defdelegate whatsapp_tier_warn?(limits, before, after_count, limit),
    to: Whatsapp.Limits,
    as: :warn?

  # CH-18
  # CH-61
  @doc "The bundled content of a WhatsApp data set, for an installation without an active version."
  @spec whatsapp_bundled(String.t()) :: map()
  defdelegate whatsapp_bundled(name), to: Whatsapp.Bundled, as: :content

  # CH-60
  @doc "The cost of a reported WhatsApp message from its `pricing` object and a rate card; see `Relay.Channels.Whatsapp.Pricing.cost/3`."
  @spec whatsapp_cost(map(), map() | nil, String.t() | nil) :: Whatsapp.Pricing.cost()
  defdelegate whatsapp_cost(card, pricing, country), to: Whatsapp.Pricing, as: :cost
end
