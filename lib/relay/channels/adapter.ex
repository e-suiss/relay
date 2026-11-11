defmodule Relay.Channels.Adapter do
  @moduledoc """
  The common port of every channel adapter (CH-1, CH-2, C-44). Relay uses the provider's transport and never replaces it; an adapter is thin: it turns a `Relay.Channels.Request` into one provider call and reports what the provider said, nothing more.

  An adapter decides nothing. It never retries, never sleeps, never classifies a failure and never disables a target: it returns the provider's raw code and the core maps it to one of the eight failure classes through the adapter's declared mapping (CH-7); retry, fallback, target cleanup and the breaker weight follow from the class only. The only retry authority is the job queue (T-26, INV-14), and every HTTP call goes through `Relay.Channels.http_request/1`, which never retries, never follows redirects and never turns TLS verification off (T-43).

  Results of `c:deliver/1`:

    * `{:accepted, info}`: the provider accepted the message. `info` may carry `:provider_message_id`, `:delivery_rank` (`:delivered` only for a channel whose provider acceptance is delivery evidence, never for push, DS-13), `:followups` (event codes the provider reports later, used by the fake provider) and `:detail`.
    * `{:rejected, raw}`: the provider answered with a failure: `raw.code` is the provider code as the adapter's `errors.json` names it, with `:status`, `:retry_after_ms` (the provider's `Retry-After`, CH-9), `:timestamp` (such as the APNs 410 timestamp, CH-11) and `:detail`. A provider "success" for a recipient it suppresses is a rejection whose mapping says `suppressed_success` (CH-8).
    * `{:not_sent, reason}`: the request never reached the provider (no connection); a retry is safe.
    * `{:uncertain, reason}`: the request may have reached the provider but no answer came (T-28); the declared `provider_idempotency_policy` decides what follows.

  `c:query/1` is required when the declared policy is `wait_and_query`: it asks the provider's status endpoint about the request's idempotency key and returns the outcome, `:not_received` when the provider has no such request, or `:unavailable`. `c:decode/1` turns the `response` of a test vector into the raw code the adapter would report, so the activation gate can check the adapter's own parsing against its vectors.

  `c:reports/3` reads a provider's delivery report webhook: it verifies the raw body first with the adapter's declared inbound verification (`Relay.Channels.Inbound`, T-40), then turns each report into a `t:report/0`, whose result is `{:delivered, info}`, `{:rejected, raw}` with the provider code of the adapter's `errors.json`, or `:pending` for an intermediate state. The core normalizes a report with `Relay.Channels.normalize_report/4`; the adapter decides nothing about it.

  `c:delivery_status/1` and `c:report_events/1` serve the periodic channel reconciliation (DS-22, DS-48). `c:delivery_status/1` asks the provider's status or report endpoint about one sent message, by the request's idempotency key or its `provider_message_id`, and returns the message's reports as `c:reports/3` reads them (a pending one included), `:not_received` when the provider has no such message, or `:unavailable`. `c:report_events/1` reads the e-mail events of an account between `from` and `to` from the provider's event list API, or `:unavailable`. Neither decides anything: a "not delivered" answer is recorded as evidence and never resends (INV-9, OP-41).

  `c:check_settings/1` reads the provider's own settings or status of an account through one cheap provider call, so a panel setting that silently overrides what Relay sends is caught (CH-52): it returns `:ok`, `{:mismatch, details}` with the `"setting"` that does not hold and, when known, its `"expected"` and `"actual"` values, or `{:error, reason}` when the provider could not be asked. A rejected credential is a mismatch of the `"credentials"` setting. An adapter without it cannot be verified by a check (CH-14).

  Registering an adapter means adding its module to `Relay.Channels.Registry` and its declaration directory to `priv/channels/<provider>/` (CH-71); until the declaration passes the activation gate the adapter is registered but receives no traffic (CH-2).
  """

  @type raw :: %{
          required(:code) => String.t(),
          optional(:status) => non_neg_integer() | nil,
          optional(:retry_after_ms) => non_neg_integer() | nil,
          optional(:timestamp) => DateTime.t() | nil,
          optional(:detail) => map()
        }

  @type followup :: %{
          required(:event_code) => String.t(),
          required(:after_ms) => non_neg_integer()
        }

  @type accepted :: %{
          optional(:provider_message_id) => String.t() | nil,
          optional(:delivery_rank) => :accepted | :delivered,
          optional(:followups) => [followup()],
          optional(:detail) => map()
        }

  @type result ::
          {:accepted, accepted()}
          | {:rejected, raw()}
          | {:not_sent, String.t()}
          | {:uncertain, String.t()}

  @type report :: %{
          required(:provider_message_id) => String.t() | nil,
          required(:result) => {:delivered, map()} | {:rejected, raw()} | :pending,
          required(:channel) => String.t(),
          optional(:correlation) => String.t() | nil,
          optional(:occurred_at) => DateTime.t() | nil,
          optional(:detail) => map()
        }

  @type query_result ::
          {:accepted, accepted()} | {:rejected, raw()} | :not_received | :unavailable

  @type reconcile :: %{
          required(:account) => map(),
          required(:credentials) => Relay.Redacted.t() | nil,
          required(:from) => DateTime.t(),
          required(:to) => DateTime.t(),
          required(:timeout_ms) => pos_integer()
        }

  @type check :: %{
          required(:account) => map(),
          required(:credentials) => Relay.Redacted.t() | nil,
          required(:timeout_ms) => pos_integer()
        }

  @type check_result ::
          :ok | {:mismatch, %{String.t() => String.t() | nil}} | {:error, String.t()}

  @doc "The provider code of the adapter, the name of its declaration directory."
  @callback provider() :: String.t()

  @doc "The channels the adapter sends on; they equal the channels of its declaration."
  @callback channels() :: [String.t(), ...]

  @doc "Makes one provider call for a request and reports the provider's answer."
  @callback deliver(Relay.Channels.Request.t()) :: result()

  @doc "Asks the provider's status endpoint about an uncertain request, by its idempotency key."
  @callback query(Relay.Channels.Request.t()) :: query_result()

  @doc "Decodes the `response` of a test vector into the raw code the adapter reports."
  @callback decode(map()) :: raw()

  @doc "Verifies a delivery report webhook on its raw body and reads its reports. Options: `:key` (the verification secret), `:url` (the callback URL as configured), `:token` (a token carried in the URL) and `:now`."
  @callback reports(binary(), [{String.t(), String.t()}], keyword()) ::
              {:ok, [report()]} | {:error, atom()}

  @doc "Asks the provider's status endpoint about a sent message for reconciliation and reads its reports."
  @callback delivery_status(Relay.Channels.Request.t()) :: {:ok, [report()]} | :not_received | :unavailable

  @doc "Reads the e-mail events of an account (`account`, its `credentials`, the call's `timeout_ms`) between `from` and `to` from the provider's event list API."
  @callback report_events(reconcile()) :: {:ok, [Relay.Channels.Email.Event.t()]} | :unavailable

  @doc "Reads the provider's settings or status of an account (`account`, its `credentials` and the call's `timeout_ms`) and says whether they hold."
  @callback check_settings(check()) :: check_result()

  @optional_callbacks query: 1,
                      decode: 1,
                      reports: 3,
                      check_settings: 1,
                      delivery_status: 1,
                      report_events: 1
end
