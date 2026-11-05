defmodule Relay.Channels do
  @moduledoc """
  Channel adapters, providers and failover, and the node-local circuit breakers of the providers. Other contexts use only the functions of this module.

  Every adapter implements the common port `Relay.Channels.Adapter` and declares its capabilities, evidence rows, idempotency policy, failure class mapping with test vectors, price and limit data, data residency and inbound verification as versioned data (`Relay.ChannelDeclarations`, CH-2, CH-71); a registered adapter whose declaration is incomplete receives no traffic.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Templates], exports: []

  alias Relay.ChannelDeclarations
  alias Relay.Channels.Adapter
  alias Relay.Channels.Ambiguity
  alias Relay.Channels.Breaker
  alias Relay.Channels.Inbound
  alias Relay.Channels.Outcome
  alias Relay.Channels.Registry
  alias Relay.Channels.Request
  alias Relay.Channels.Routing
  alias Relay.Channels.Simulated
  alias Relay.Channels.Sms
  alias Relay.Channels.SmsSender
  alias Relay.Channels.Store
  alias Relay.Channels.Timeouts

  require Logger

  @type digest :: <<_::256>>
  @type result(value) :: {:ok, value} | {:error, term()}

  @doc "Supervised children: the owner of the circuit breaker table."
  @spec children() :: [Supervisor.child_spec()]
  def children, do: [Supervisor.child_spec(Breaker, [])]

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
  The provider-dependent checks of an SMS or voice send on the chosen account, before the attempt opens: the account's approved sender identity; on SMS its rules for the message class (`Relay.Channels.SmsSender.check/2`), the TR route (`Relay.Channels.Sms.route/3`), the explicit encoding with its segments (`Relay.Channels.Sms.encoding/3`) and the provider product (`Relay.Channels.Sms.product/2`). Returns the request fields to add, or `{:skip, rule_id}`; other channels pass unchanged.
  """
  @spec sms_preflight(
          Relay.Scope.t(),
          ChannelDeclarations.t(),
          map(),
          map(),
          String.t(),
          map() | binary()
        ) :: {:ok, map()} | {:skip, String.t()}
  def sms_preflight(scope, declarations, account, delivery, number, content) do
    if delivery["channel"] in ["sms", "voice"],
      do: preflight(scope, declarations, account, delivery, number, content),
      else: {:ok, %{}}
  end

  defp preflight(scope, declarations, account, delivery, number, content) do
    with {:ok, sender} <- account_sender(scope, account),
         {:ok, declaration} <- declaration(declarations, account["provider"]) do
      if delivery["channel"] == "sms",
        do: Sms.preflight(declaration, sender, delivery["message_class"], number, content),
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
    if Sms.turkish_number?(number) do
      Enum.filter(accounts, fn account ->
        case ChannelDeclarations.declaration(declarations, account["provider"]) do
          {:ok, declaration} -> Sms.btk_authorized?(declaration)
          {:error, :unknown_provider} -> false
        end
      end)
    else
      accounts
    end
  end

  # C-45
  @doc "Records the health of a provider account."
  @spec set_account_health(Relay.Scope.t(), Relay.Id.t(), String.t()) :: result(atom())
  def set_account_health(scope, id, health),
    do: Store.in_scope(scope, fn _status -> Store.account_set_health(id, health) end)

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

  # CH-13
  # CH-14
  # INV-43
  @doc "The provider route of a channel in a scope: the usable accounts in order and the excluded ones with their reason; see `Relay.Channels.Routing.route/5`."
  @spec routes(Relay.Scope.t(), String.t(), ChannelDeclarations.t(), Routing.policy()) ::
          result({[Routing.account()], [Routing.excluded()]})
  def routes(scope, channel, %ChannelDeclarations{} = declarations, policy) do
    Store.in_scope(scope, fn _status ->
      accounts = Store.accounts(channel)
      ids = Enum.map(accounts, & &1["id"])
      senders = Enum.group_by(Store.senders(ids), & &1["provider_account_id"])
      activated? = &match?({:ok, _adapter}, Registry.activated(declarations, &1))
      Routing.route(accounts, senders, activated?, declarations, policy)
    end)
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
end
