defmodule Relay.FaultInjection do
  @moduledoc """
  Fault injection for game days and chaos tests (OP-92, OP-49): a record of its own that reuses the kill switch's scope model (the installation or one tenant, then a channel and a provider), its kind (`provider_auth_error`, `rate_limited_429`, `concurrency_exhausted`, `bounce_spike`, `template_paused`, `delayed_delivery_report`, `iys_pull_stalled`, `added_latency`), its rate from 0 to 100 percent and a TTL of at most one hour (OP-78).

  A record is accepted only for the `test` environment, or for `live` when the installation runs with `RELAY_CHAOS_MODE=true`; any other is refused with `:not_permitted` before it reaches the database, and a `live` record that reached the database another way is inert on a node that is not in chaos mode (`Relay.FaultInjection.Evaluation`). Engaging and clearing are operator actions of the operator API and the release command `Relay.Release.FaultInjection`: each is authorized as an installation operator's, written with its audit record (`fault_injection.engaged`, `fault_injection.cleared`) and signalled to the nodes after it commits. Both are idempotent: engaging a record whose dimensions match one in force answers that record, and clearing a cleared record answers `:already_cleared` (OP-44). A record expires by itself.

  The delivery path reads the node's cached records (`Relay.FaultInjection.Cache`) through `provider_fault/1`, `report_delay/2` and `iys_pull_stalled?/1`; while no record is in force each is one `:persistent_term` lookup.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Platform, Relay.Audit], exports: []

  require Logger

  alias Relay.Actor
  alias Relay.FaultInjection.Cache
  alias Relay.FaultInjection.Evaluation
  alias Relay.FaultInjection.Record
  alias Relay.FaultInjection.Store

  @max_ttl_s 3_600
  @max_latency_ms 10_000
  @max_delay_ms 3_600_000
  @timed [:added_latency, :delayed_delivery_report]
  @channels ~w(push web_push email sms voice whatsapp in_app slack teams telegram discord)

  @type operator :: %{
          required(:kind) => :installation_operator,
          required(:ref) => String.t(),
          optional(:access_record_ref) => String.t() | nil
        }
  @type provider_fault :: nil | {:fail, Record.kind()} | {:delay, pos_integer()}

  @doc "Supervised children: the node's fault injection cache, unless `config :relay, Relay.FaultInjection, cache: false`."
  @spec children() :: [Supervisor.child_spec()]
  def children do
    if Keyword.get(config(), :cache, true), do: [Supervisor.child_spec(Cache, [])], else: []
  end

  # OP-92
  @doc "True when the installation runs in chaos mode (`RELAY_CHAOS_MODE=true`), which lets a fault injection target the `live` environment."
  @spec chaos_mode?() :: boolean()
  def chaos_mode?, do: Keyword.get(config(), :chaos_mode, false) == true

  @doc "The kinds of a fault injection."
  @spec kinds() :: [Record.kind(), ...]
  def kinds, do: Record.kinds()

  # OP-92
  # OP-44
  # OP-78
  @doc """
  Engages a fault injection. `spec` carries `:scope_kind` (`:installation` or `:tenant`), `:tenant_id` for a tenant record, `:environment` (`:live` or `:test`), the optional `:channel` and `:provider`, `:kind`, `:rate_percent` (0–100), `:delay_ms` for `added_latency` (at most 10 000) and `delayed_delivery_report` (at most one hour), `:reason` and `:ttl_seconds` (1–3600). Returns `{:ok, %{result: :engaged | :exists, id: "fij_…"}}`; `:exists` names the record in force of the same dimensions. `opts`: `:chaos_mode` (defaults to `chaos_mode?/0`).
  """
  @spec engage(map(), operator(), keyword()) :: {:ok, map()} | {:error, atom()}
  def engage(spec, operator, opts \\ []) do
    chaos? = Keyword.get_lazy(opts, :chaos_mode, &chaos_mode?/0)

    with {:ok, actor} <- actor(operator),
         {:ok, attrs} <- attrs(spec),
         :ok <- permitted(attrs.target_environment, chaos?) do
      digest = digest("fault_injection.engaged", actor, attrs.id, attrs.reason)
      engaged(Store.engage(attrs, digest, actor))
    end
  end

  # OP-92
  # OP-44
  @doc "Clears a fault injection with a reason. Returns `{:ok, %{result: :cleared | :already_cleared, id: \"fij_…\"}}`."
  @spec clear(String.t() | Relay.Id.t(), String.t() | nil, operator()) ::
          {:ok, map()} | {:error, atom()}
  def clear(id, reason, operator) do
    with {:ok, actor} <- actor(operator),
         {:ok, reason} <- reason(reason),
         {:ok, fault_injection_id} <- decode_id(id) do
      digest = digest("fault_injection.cleared", actor, fault_injection_id, reason)
      cleared(fault_injection_id, Store.clear(fault_injection_id, reason, digest, actor))
    end
  end

  defp engaged({:ok, {result, id}}) when result in [:engaged, :exists] do
    if result == :engaged, do: announce()
    {:ok, %{result: result, id: Record.external_id(id)}}
  end

  defp engaged({:ok, {code, _id}}), do: {:error, code}
  defp engaged({:error, error}), do: {:error, error_code(error)}

  defp cleared(id, {:ok, result}) when result in [:cleared, :already_cleared] do
    if result == :cleared, do: announce()
    {:ok, %{result: result, id: Record.external_id(id)}}
  end

  defp cleared(_id, {:ok, code}), do: {:error, code}
  defp cleared(_id, {:error, error}), do: {:error, error_code(error)}

  # OP-92
  @doc "Lists the records, newest first. `opts`: `:include_inactive` (cleared and expired records too) and `:limit` (at most 1000)."
  @spec list(keyword()) :: {:ok, [Record.t()]} | {:error, atom()}
  def list(opts \\ []) do
    include_inactive = Keyword.get(opts, :include_inactive, false)

    case Store.list(include_inactive, Keyword.get(opts, :limit, 100)) do
      {:ok, records} -> {:ok, records}
      {:error, error} -> {:error, error_code(error)}
    end
  end

  @doc "Reads one record, in force or not."
  @spec show(String.t() | Relay.Id.t()) :: {:ok, Record.t()} | {:error, atom()}
  def show(id) do
    with {:ok, fault_injection_id} <- decode_id(id),
         {:ok, records} <- list(include_inactive: true, limit: 1_000) do
      case Enum.find(records, &(&1.id == fault_injection_id)) do
        nil -> {:error, :not_found}
        record -> {:ok, record}
      end
    end
  end

  @doc "Describes a record for an operator."
  @spec describe(Record.t()) :: map()
  def describe(%Record{} = record) do
    %{
      id: Record.external_id(record.id),
      scope: record.scope_kind,
      tenant: record.scope_tenant_id && Relay.ExternalId.encode("ten", record.scope_tenant_id),
      environment: record.target_environment,
      channel: record.channel,
      provider: record.provider,
      kind: record.kind,
      rate_percent: record.rate_percent,
      delay_ms: record.delay_ms,
      reason: record.reason,
      created_by: record.created_by_ref,
      expires_at: record.expires_at,
      status: record.status,
      created_at: record.created_at
    }
  end

  # OP-92
  @doc """
  The fault of a provider call at `point` (`:tenant_id`, `:environment`, `:channel`, `:provider`): `{:fail, kind}` for a failure the call answers instead of the provider, `{:delay, ms}` for latency added before the real call, or nil. `opts`: `:records` (defaults to the node's cached records), `:draw` (a function returning 1..100, defaults to `Relay.Random.uniform/1`), `:now` and `:chaos_mode`.
  """
  @spec provider_fault(Evaluation.point(), keyword()) :: provider_fault()
  def provider_fault(point, opts \\ []) do
    case records(opts) do
      [] ->
        nil

      records ->
        case pick(records, Record.provider_kinds(), point, opts) do
          nil -> nil
          %Record{kind: :added_latency, delay_ms: ms} -> {:delay, ms}
          %Record{kind: kind} -> {:fail, kind}
        end
    end
  end

  # OP-92
  @doc "The delay a delivery report waits at `point` (`:tenant_id`, `:environment`, the optional `:channel` and `:provider`): the record's `delay_ms` when a `delayed_delivery_report` record applies and `key` (an integer such as a job identifier) falls within its rate, so a retried report keeps its decision; otherwise 0. `opts` as `provider_fault/2`."
  @spec report_delay(Evaluation.point(), non_neg_integer(), keyword()) :: non_neg_integer()
  def report_delay(point, key, opts \\ []) when is_integer(key) do
    case records(opts) do
      [] ->
        0

      records ->
        opts = Keyword.put(opts, :draw, fn -> rem(key, 100) + 1 end)

        case pick(records, [:delayed_delivery_report], point, opts) do
          %Record{delay_ms: ms} when is_integer(ms) -> ms
          _none -> 0
        end
    end
  end

  # OP-92
  # OP-49
  @doc "True when the İYS pull of `scope` is stalled by an `iys_pull_stalled` record. `opts` as `provider_fault/2`."
  @spec iys_pull_stalled?(Relay.Scope.t(), keyword()) :: boolean()
  def iys_pull_stalled?(%Relay.Scope{} = scope, opts \\ []) do
    case records(opts) do
      [] ->
        false

      records ->
        point = %{tenant_id: scope.tenant_id, environment: scope.environment}
        pick(records, [:iys_pull_stalled], point, opts) != nil
    end
  end

  defp records(opts), do: Keyword.get_lazy(opts, :records, &Cache.current/0)

  defp pick(records, kinds, point, opts) do
    now = Keyword.get_lazy(opts, :now, &Relay.Clock.utc_now/0)
    chaos? = Keyword.get_lazy(opts, :chaos_mode, &chaos_mode?/0)

    case Evaluation.find(records, kinds, point, now, chaos?) do
      nil ->
        nil

      record ->
        draw = Keyword.get(opts, :draw, fn -> Relay.Random.uniform(100) end)

        if Evaluation.hit?(record, draw.()) do
          :telemetry.execute([:relay, :fault_injection, :injected], %{count: 1}, %{
            kind: record.kind
          })

          record
        end
    end
  end

  defp permitted(environment, chaos?) do
    if Evaluation.permitted?(environment, chaos?), do: :ok, else: {:error, :not_permitted}
  end

  defp attrs(spec) do
    with {:ok, scope_kind, tenant_id} <- scope(spec),
         {:ok, environment} <- environment(spec[:environment]),
         {:ok, kind} <- kind(spec[:kind]),
         {:ok, channel} <- channel(spec[:channel], kind),
         {:ok, provider} <- provider(spec[:provider], kind),
         {:ok, rate} <- rate(spec[:rate_percent]),
         {:ok, delay_ms} <- delay(kind, spec[:delay_ms]),
         {:ok, ttl} <- ttl(spec[:ttl_seconds]),
         {:ok, reason} <- reason(spec[:reason]) do
      {:ok,
       %{
         id: Relay.Id.generate(),
         scope_kind: scope_kind,
         scope_tenant_id: tenant_id,
         target_environment: environment,
         channel: channel,
         provider: provider,
         kind: kind,
         rate_percent: rate,
         delay_ms: delay_ms,
         reason: reason,
         ttl_seconds: ttl
       }}
    end
  end

  defp scope(%{scope_kind: :installation}), do: {:ok, :installation, nil}
  defp scope(%{scope_kind: :tenant, tenant_id: <<_::128>> = id}), do: {:ok, :tenant, id}
  defp scope(%{scope_kind: :tenant}), do: {:error, :tenant_required}
  defp scope(_spec), do: {:error, :invalid_scope}

  defp environment(environment) do
    case Relay.Environment.cast(environment) do
      {:ok, environment} -> {:ok, environment}
      {:error, _} -> {:error, :invalid_environment}
    end
  end

  defp kind(kind) when is_atom(kind) and not is_nil(kind) do
    if kind in Record.kinds(), do: {:ok, kind}, else: {:error, :invalid_kind}
  end

  defp kind(kind) when is_binary(kind) do
    case Enum.find(Record.kinds(), &(Atom.to_string(&1) == kind)) do
      nil -> {:error, :invalid_kind}
      kind -> {:ok, kind}
    end
  end

  defp kind(_kind), do: {:error, :invalid_kind}

  defp channel(nil, _kind), do: {:ok, nil}
  defp channel(_channel, :iys_pull_stalled), do: {:error, :invalid_channel}
  defp channel(channel, kind) when is_atom(channel), do: channel(Atom.to_string(channel), kind)
  defp channel(channel, _kind) when channel in @channels, do: {:ok, channel}
  defp channel(_channel, _kind), do: {:error, :invalid_channel}

  defp provider(nil, _kind), do: {:ok, nil}
  defp provider(_provider, :iys_pull_stalled), do: {:error, :invalid_provider}

  defp provider(provider, _kind) when is_binary(provider) do
    if provider =~ ~r/\A[a-z][a-z0-9_]{0,63}\z/,
      do: {:ok, provider},
      else: {:error, :invalid_provider}
  end

  defp provider(_provider, _kind), do: {:error, :invalid_provider}

  defp rate(rate) when is_integer(rate) and rate in 0..100, do: {:ok, rate}
  defp rate(_rate), do: {:error, :invalid_rate}

  defp delay(:added_latency, ms) when is_integer(ms) and ms in 1..@max_latency_ms, do: {:ok, ms}

  defp delay(:delayed_delivery_report, ms) when is_integer(ms) and ms in 1..@max_delay_ms,
    do: {:ok, ms}

  defp delay(kind, _ms) when kind in @timed, do: {:error, :invalid_delay}
  defp delay(_kind, nil), do: {:ok, nil}
  defp delay(_kind, _ms), do: {:error, :invalid_delay}

  defp ttl(ttl) when is_integer(ttl) and ttl in 1..@max_ttl_s, do: {:ok, ttl}
  defp ttl(_ttl), do: {:error, :invalid_ttl}

  defp reason(reason) when is_binary(reason) do
    if String.trim(reason) != "" and String.length(reason) <= 2_000,
      do: {:ok, reason},
      else: {:error, :reason_required}
  end

  defp reason(_reason), do: {:error, :reason_required}

  defp decode_id(<<_::128>> = id), do: {:ok, id}

  defp decode_id(text) when is_binary(text) do
    case Relay.ExternalId.decode(text, ["fij"]) do
      {:ok, id} -> {:ok, id}
      {:error, _} -> {:error, :invalid_id}
    end
  end

  defp decode_id(_id), do: {:error, :invalid_id}

  # TN-48
  defp actor(%{kind: :installation_operator, ref: ref} = operator)
       when is_binary(ref) and byte_size(ref) in 1..256 do
    if String.trim(ref) == "" do
      {:error, :operator_required}
    else
      {:ok,
       %Actor{
         kind: :installation_operator,
         ref: ref,
         on_behalf_of_ref: ref,
         access_record_ref: Map.get(operator, :access_record_ref)
       }}
    end
  end

  defp actor(_operator), do: {:error, :installation_operator_required}

  defp digest(action, actor, id, reason) do
    scope = Store.installation_scope()

    Relay.Audit.record_digest(%{
      tenant_id: scope.tenant_id,
      environment: Relay.Environment.dump(scope.environment),
      action: action,
      actor_kind: Atom.to_string(actor.kind),
      actor_ref: actor.ref,
      on_behalf_of_ref: actor.on_behalf_of_ref,
      access_record_ref: actor.access_record_ref,
      target_type: "fault_injection",
      target_id: Relay.Id.to_string(id),
      reason: reason
    })
  end

  # OP-92
  @doc "Signals the nodes that the fault injection records changed; call it after the writing transaction commits."
  @spec announce() :: :ok
  def announce do
    topic = Cache.topic()
    seq = DateTime.to_unix(Relay.Clock.utc_now(), :millisecond)

    with {:error, error} <- Relay.Platform.publish_signal(topic, seq),
         do: Logger.warning("fault injection signal not sent; nodes poll", code: error.code)

    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> send(pid, {:relay_signal, topic, :poll})
    end

    :ok
  end

  defp error_code(%Relay.Error{code: code}), do: code
  defp error_code(code) when is_atom(code), do: code
  defp error_code(_error), do: :fault_injection_unavailable

  defp config, do: Application.get_env(:relay, __MODULE__, [])
end
