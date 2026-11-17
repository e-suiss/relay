defmodule Relay.Access.Pairing do
  @moduledoc """
  Relay's pairing with the Access environments of the Access tenants (E-101, E-103, Access OP-149 m.16–19). Relay is a `platform_product` client of Access with two keys in the key store: the client key that signs every RFC 7523 client assertion (`Relay.Access.Client`, E-100) and the Ed25519 service key of Relay's service Instance in every Access environment (`Relay.Access.ServiceKey`). `run/2` is the one code path of every trigger: node start, the hourly run, `tenant.created` and the operator's manual run (`request/1`).

  For each active tenant (scope `:due` and `:all`), or one tenant (`{:tenant, id}`), a run reads the tenant snapshot (`Relay.Access.Environments`), records its live Access environments and retires the others, and, when a live Access environment is not paired under the service key (always for `:all` and a single tenant), asks `pairing_challenges` for challenges. A `paired` target is stored as it is, a `refused` one is stored with Access's code, and an `unpaired` one is stored and signed only when every check holds: the kernel-free checks of `Relay.Access.Pairing.Target.check/3` and those of the signer (`Relay.Access.Pairing.Signer`, by default `Relay.Access.Pairing.KernelSigner`), which recomputes the intent digests and signs the Actor Intent Statements. Every signed target goes to `pairing`, at most 64 per request, and the stream the answer names is adopted. Each answer names the Access environments with the member the challenges named them with (`Relay.Access.Pairing.Target`). A `400 invalid-challenge`, a `503` or a network failure is tried once more with a new challenge. An Access environment that does not end paired counts a failed run; three in a row are an operator signal.

  The run then checks Relay's Access event stream through `platform_streams`: an enabled stream is up, a paused or unreachable one is a warning, and a missing or disabled one is opened again towards Relay's receiver (`config :relay, Relay.Access, event_receiver: url`). Every call carries a fresh client assertion, nothing else.

  Telemetry: `[:relay, :access, :pairing]` with `unpaired_access_environments` (Access environments not paired after three runs in a row, the `relay_access_pairing_unpaired_access_environments` alarm) and `stream_up` (1 while the event stream is enabled). Every signal is logged.
  """

  require Logger

  alias Relay.Access.Cache
  alias Relay.Access.Client
  alias Relay.Access.Discovery
  alias Relay.Access.Environments
  alias Relay.Access.Http
  alias Relay.Access.Pairing.Job
  alias Relay.Access.Pairing.KernelSigner
  alias Relay.Access.Pairing.Store
  alias Relay.Access.Pairing.Streams
  alias Relay.Access.Pairing.Target
  alias Relay.Access.ServiceKey

  @stalled_runs 3
  @request_ms 300_000
  @page 100
  @slug_bytes 1..255

  @type scope :: :due | :all | {:tenant, String.t()}
  @type signal :: {atom(), map()}
  @type report :: %{
          tenants: non_neg_integer(),
          paired: non_neg_integer(),
          signals: [signal()],
          unpaired_access_environments: non_neg_integer() | nil,
          stream_up: boolean(),
          event_stream: String.t() | nil
        }

  @doc "Failed runs in a row after which an Access environment is an operator signal."
  @spec stalled_runs() :: pos_integer()
  def stalled_runs, do: @stalled_runs

  # E-101
  @doc "Queues a pairing run of `scope` on the `maintenance` queue; a node queues a scope at most once every five minutes. The operator's manual run: `bin/relay rpc 'Relay.Access.Pairing.request(:all)'`, or `{:tenant, \"tnt_…\"}` for one tenant."
  @spec request(scope()) :: :ok | {:error, term()}
  def request(scope) do
    if Cache.claim({:pairing_request, scope}, @request_ms), do: queue(scope), else: :ok
  end

  defp queue(scope) do
    case Oban.insert(Job.new(Job.args(scope))) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # E-101
  @doc "The child of the start-up run: it starts no process of its own."
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg),
    do: %{id: __MODULE__, start: {__MODULE__, :start, []}, restart: :temporary}

  # E-101
  # T-47
  @doc "Queues the start-up run from a background task, unless `config :relay, Relay.Access, autoload: false`; always `:ignore`."
  @spec start() :: :ignore
  def start do
    if Keyword.get(Relay.Access.config(), :autoload, true) do
      Logger.metadata(correlation_id: Relay.Id.to_string(Relay.Id.generate()))
      {:ok, _pid} = Relay.Process.start_task(fn -> request(:due) end)
      Logger.metadata(correlation_id: nil)
    end

    :ignore
  end

  # E-101
  @doc "Runs the pairing of `scope` and the event stream check, and returns what it did. Options: `:signer`, the `Relay.Access.Pairing.Signer` module; `:http`, extra Req options of the Access calls; `:receiver`, the event receiver instead of the configured one."
  @spec run(scope(), keyword()) :: report()
  def run(scope, opts \\ []) do
    report = %{
      tenants: 0,
      paired: 0,
      signals: [],
      unpaired_access_environments: nil,
      stream_up: false,
      event_stream: nil
    }

    report =
      case context(opts) do
        {:ok, ctx} -> report |> tenants(scope, ctx) |> stream(ctx)
        {:error, error} -> signal(report, :failed, %{tenant: nil, error: error})
      end

    report |> gauges() |> finish()
  end

  defp context(opts) do
    http = Keyword.get(opts, :http, [])

    with {:ok, issuer} <- setting(Relay.Access.issuer(), "no Access issuer is configured"),
         {:ok, client_id} <- setting(Relay.Access.client_id(), "no Access client_id is set"),
         {:ok, receiver} <- setting(receiver(opts), "no Access event receiver is configured"),
         {:ok, endpoints} <- endpoints(issuer, http),
         {:ok, key} <- ServiceKey.public_key() do
      {:ok,
       %{
         endpoints: endpoints,
         key: key,
         kid: ServiceKey.thumbprint(key),
         receiver: receiver,
         client_id: client_id,
         http: http,
         signer: Keyword.get(opts, :signer, KernelSigner),
         region: Relay.Datasets.installation_region()
       }}
    end
  end

  defp receiver(opts),
    do: Keyword.get_lazy(opts, :receiver, fn -> Relay.Access.config()[:event_receiver] end)

  defp setting(value, _message) when is_binary(value) and value != "", do: {:ok, value}
  defp setting(_value, message), do: {:error, Relay.Error.new(:access_not_configured, message)}

  defp endpoints(issuer, http) do
    with {:ok, document, _raw} <- Http.get_json(Discovery.suiss_url(issuer), http),
         {:ok, suiss} <- Discovery.parse_suiss(document, issuer) do
      case suiss do
        %{pairing_challenges: c, pairing: p, platform_streams: s}
        when is_binary(c) and is_binary(p) and is_binary(s) ->
          {:ok, %{challenges: c, pairing: p, streams: s}}

        _missing ->
          {:error, Relay.Error.new(:access_discovery_invalid, "Access names no pairing routes")}
      end
    end
  end

  defp tenants(report, {:tenant, tenant}, ctx), do: tenant(report, tenant, true, ctx)
  defp tenants(report, scope, ctx), do: page(report, nil, scope == :all, ctx)

  defp page(report, after_id, force, ctx) do
    list = Store.tenants(after_id, @page)
    report = Enum.reduce(list, report, &tenant(&2, &1, force, ctx))

    if length(list) < @page,
      do: report,
      else: page(report, List.last(list), force, ctx)
  end

  defp tenant(report, tenant, force, ctx) do
    case Environments.snapshot(tenant) do
      {:ok, snapshot} -> snapshot_step(report, tenant, snapshot, force, ctx)
      {:error, :not_found} -> report
      {:error, error} -> signal(report, :failed, %{tenant: tenant, error: error})
    end
  end

  defp snapshot_step(report, tenant, snapshot, force, ctx) do
    case live_environments(tenant, snapshot, ctx.region) do
      {:ok, live} ->
        _retired = Store.seen(tenant, live)
        report = %{report | tenants: report.tenants + 1}
        due(report, tenant, live, force, ctx)

      :skip ->
        report

      :error ->
        signal(report, :failed, %{tenant: tenant, error: :invalid_snapshot})
    end
  end

  defp due(report, _tenant, [], _force, _ctx), do: report

  defp due(report, tenant, live, force, ctx) do
    stored = Store.access_environments(tenant)

    if force or Enum.any?(live, &(not held?(stored, elem(&1, 0), ctx.kid))),
      do: pair(report, %{tenant: tenant, live: live, stored: stored}, ctx),
      else: report
  end

  # INV-41
  # E-103
  defp live_environments(tenant, snapshot, region) do
    case Environments.listed(snapshot, tenant) do
      {:ok, listed} -> live(listed, snapshot, region)
      :error -> :error
    end
  end

  defp live(listed, snapshot, region) do
    cond do
      snapshot["status"] != "active" or snapshot["region"] != region -> :skip
      Enum.all?(listed, &listed?/1) -> distinct(Enum.map(listed, &{&1["id"], &1["slug"]}))
      true -> :error
    end
  end

  defp listed?(%{"id" => id, "slug" => slug}) when is_binary(slug),
    do: Target.uuid?(id) and byte_size(slug) in @slug_bytes

  defp listed?(_listed), do: false

  defp distinct(live) do
    if length(Enum.uniq_by(live, &elem(&1, 0))) == length(live), do: {:ok, live}, else: :error
  end

  defp held?(stored, id, kid),
    do: Enum.any?(stored, &paired?(&1, id, kid))

  defp paired?(stored, id, kid),
    do: stored.access_environment == id and stored.state == :paired and stored.kid == kid

  defp pair(report, job, ctx) do
    fresh = %{failed: MapSet.new(), paired: MapSet.new(), stream: nil, signals: []}
    {outcome, acc} = attempt(job, fresh, ctx)

    {outcome, acc} =
      if retryable?(outcome),
        do: attempt(job, %{acc | failed: MapSet.new()}, ctx),
        else: {outcome, acc}

    failed = failed_after(outcome, acc, job, ctx.kid)
    report = %{report | signals: acc.signals ++ report.signals}
    report = count_failures(report, job.tenant, failed)
    report = %{report | paired: report.paired + MapSet.size(acc.paired)}

    case outcome do
      :ok -> %{report | event_stream: acc.stream || report.event_stream}
      {:error, reason} -> signal(report, :failed, %{tenant: job.tenant, error: reason})
    end
  end

  defp retryable?({:error, {:refused, 400, "invalid-challenge"}}), do: true
  defp retryable?({:error, {:refused, 503, _code}}), do: true
  defp retryable?({:error, {:network, _error}}), do: true
  defp retryable?(_outcome), do: false

  defp failed_after(:ok, acc, _job, _kid), do: acc.failed

  defp failed_after({:error, _reason}, acc, job, kid) do
    job.live
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&(held?(job.stored, &1, kid) or MapSet.member?(acc.paired, &1)))
    |> MapSet.new()
    |> MapSet.union(acc.failed)
  end

  defp count_failures(report, tenant, failed) do
    Enum.reduce(failed, report, fn id, report ->
      case Store.change(tenant, id, :failed) do
        {:ok, runs} when runs >= @stalled_runs ->
          signal(report, :unpaired, %{tenant: tenant, access_environment: id, runs: runs})

        _counted ->
          report
      end
    end)
  end

  defp attempt(job, acc, ctx) do
    url = expand(ctx.endpoints.challenges, job.tenant)

    with {:ok, document} <- call(:post, url, nil, 201, ctx),
         {:ok, answer} <- answer(document, job.tenant) do
      {acc, signed} = plan(answer.targets, job, acc, ctx, now_ms())
      job = Map.put(job, :field, answer.field)

      signed
      |> Enum.chunk_every(Target.max_targets())
      |> Enum.reduce_while({:ok, acc}, &send_chunk(&1, &2, job, ctx))
    else
      {:error, reason} -> {{:error, reason}, acc}
    end
  end

  defp send_chunk(chunk, {:ok, acc}, job, ctx) do
    {:ok, body} = Target.pairing_body(chunk, job.field)
    url = expand(ctx.endpoints.pairing, job.tenant)

    with {:ok, document} <- call(:post, url, body, 200, ctx),
         {:ok, answer} <- answer(document, job.tenant) do
      acc = Enum.reduce(chunk, acc, &result(&1.access_environment, answer.targets, job, &2))
      {:cont, {:ok, %{acc | stream: answer.event_stream || acc.stream}}}
    else
      {:error, reason} -> {:halt, {{:error, reason}, acc}}
    end
  end

  defp plan(targets, job, acc, ctx, now) do
    Enum.reduce(targets, {acc, []}, fn target, {acc, signed} ->
      case target do
        %{status: :unpaired} -> challenged(target, job, acc, signed, {ctx, now})
        _other -> {settled(target, job, acc), signed}
      end
    end)
  end

  defp result(id, targets, job, acc) do
    case Enum.find(targets, &(&1.access_environment == id)) do
      %{status: status} = target when status in [:paired, :refused] -> settled(target, job, acc)
      _unpaired_or_missing -> %{acc | failed: MapSet.put(acc.failed, id)}
    end
  end

  defp settled(%{status: :paired} = target, job, acc) do
    id = target.access_environment
    fields = %{kid: target.kid, domain: nil, party: target.party, instance: target.instance}
    _stored = Store.change(job.tenant, id, {:paired, fields})
    first? = not MapSet.member?(acc.paired, id)
    acc = %{acc | failed: MapSet.delete(acc.failed, id)}
    acc = %{acc | paired: MapSet.put(acc.paired, id)}

    if first? and refused_before?(job.stored, id),
      do: add(acc, :cleared, %{tenant: job.tenant, access_environment: id, slug: slug(job, id)}),
      else: acc
  end

  defp settled(%{status: :refused} = target, job, acc) do
    id = target.access_environment
    _stored = Store.change(job.tenant, id, {:refused, target.code})
    acc = %{acc | failed: MapSet.put(acc.failed, id)}
    meta = %{tenant: job.tenant, access_environment: id, slug: slug(job, id), code: target.code}
    add(acc, :refused, meta)
  end

  defp challenged(target, job, acc, signed, {ctx, now}) do
    fields = %{kid: target.kid, domain: target.domain, party: target.party}
    id = target.access_environment
    _stored = Store.change(job.tenant, id, {:unpaired, fields})

    case sign(target, ctx, now) do
      {:ok, one} ->
        {acc, [one | signed]}

      {:error, code} ->
        acc = %{acc | failed: MapSet.put(acc.failed, id)}
        meta = %{tenant: job.tenant, access_environment: id, code: code}
        {add(acc, :unsignable, meta), signed}
    end
  end

  # E-101
  defp sign(target, ctx, now) do
    with :ok <- Target.check(target, ctx.kid, now),
         {:ok, signed} <- signer_result(ctx.signer.sign(target, ctx.key, now)) do
      {:ok,
       %{
         access_environment: target.access_environment,
         challenge: target.challenge,
         ais: signed.ais,
         register_ais: signed.register_ais
       }}
    end
  end

  defp signer_result({:ok, %{ais: ais} = signed}) when is_binary(ais), do: {:ok, signed}
  defp signer_result({:error, {:unsignable, code}}) when is_binary(code), do: {:error, code}
  defp signer_result(_failed), do: {:error, "pairing-signer"}

  defp refused_before?(stored, id),
    do: Enum.any?(stored, &(&1.access_environment == id and &1.state == :refused))

  defp slug(job, id) do
    case List.keyfind(job.live, id, 0) do
      {_id, slug} -> slug
      nil -> id
    end
  end

  defp answer(document, tenant) do
    case Target.parse(document, tenant) do
      {:ok, answer} -> {:ok, answer}
      :error -> {:error, {:invalid, "Access answered an invalid pairing document"}}
    end
  end

  defp call(method, url, body, expected, ctx) do
    case Client.product_request(method, url, body, http: ctx.http) do
      {:ok, %Req.Response{status: ^expected, body: raw}} -> decode(raw)
      {:ok, %Req.Response{status: status, body: raw}} -> {:error, {:refused, status, code(raw)}}
      {:error, %Relay.Error{code: :access_unreachable} = error} -> {:error, {:network, error}}
      {:error, error} -> {:error, error}
    end
  end

  defp decode(raw) do
    case Http.json(raw) do
      {:ok, document, _raw} -> {:ok, document}
      {:error, _error} -> {:error, {:invalid, "Access answered no JSON object"}}
    end
  end

  defp code(raw) do
    case Http.json(raw) do
      {:ok, %{"code" => code}, _raw} when is_binary(code) -> code
      _other -> nil
    end
  end

  defp expand(template, tenant),
    do: String.replace(template, "{tenant}", URI.encode(tenant, &URI.char_unreserved?/1))

  defp stream(report, ctx) do
    known =
      case Store.stream() do
        %{stream: id} -> id
        nil -> nil
      end

    case find_stream(adopt(report.event_stream, known), ctx) do
      {:ok, found} -> act(Streams.check(found), found, report, ctx)
      {:error, reason} -> signal(report, :failed, %{tenant: nil, error: reason})
    end
  end

  defp adopt(seen, known) when is_binary(seen) and is_binary(known) and seen != known, do: nil
  defp adopt(seen, _known) when is_binary(seen), do: seen
  defp adopt(nil, known), do: known

  defp find_stream(nil, ctx) do
    with {:ok, list} <- list_streams(ctx), do: {:ok, Streams.live(list, ctx.receiver)}
  end

  defp find_stream(id, ctx) do
    case call(:get, ctx.endpoints.streams <> "/" <> id, nil, 200, ctx) do
      {:ok, document} -> parsed_stream(document)
      {:error, {:refused, 404, "no-such-stream"}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_streams(ctx) do
    with {:ok, document} <- call(:get, ctx.endpoints.streams, nil, 200, ctx) do
      case Streams.parse_list(document) do
        {:ok, list} -> {:ok, list}
        :error -> {:error, {:invalid, "Access answered an invalid stream list"}}
      end
    end
  end

  defp parsed_stream(document) do
    case Streams.parse(document) do
      {:ok, stream} -> {:ok, stream}
      :error -> {:error, {:invalid, "Access answered an invalid stream"}}
    end
  end

  defp act(:up, found, report, _ctx), do: recorded(report, found, false)

  defp act({:down, status}, found, report, _ctx) do
    report
    |> signal(:stream_down, %{stream: found.id, status: status})
    |> recorded(found, false)
  end

  defp act(:reopen, found, report, ctx) do
    with {:ok, list} <- list_streams(ctx),
         events = Streams.requested(list ++ List.wrap(found)),
         {:ok, opened} <- open_stream(events, ctx) do
      reopened(opened, report, ctx)
    else
      {:error, reason} -> signal(report, :failed, %{tenant: nil, error: reason})
    end
  end

  defp open_stream(events, ctx) do
    body = Streams.create_body(ctx.receiver, ctx.client_id, events)

    case call(:post, ctx.endpoints.streams, body, 201, ctx) do
      {:ok, document} -> parsed_stream(document)
      {:error, {:refused, 409, "stream-exists"}} -> {:ok, :exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reopened(:exists, report, ctx) do
    case list_streams(ctx) do
      {:ok, list} -> recorded(report, Streams.live(list, ctx.receiver), false)
      {:error, reason} -> signal(report, :failed, %{tenant: nil, error: reason})
    end
  end

  defp reopened(stream, report, _ctx) do
    report
    |> signal(:stream_recreated, %{stream: stream.id})
    |> recorded(stream, true)
  end

  defp recorded(report, nil, recreated?) do
    _count = Store.record_stream(nil, nil, recreated?)
    %{report | stream_up: false}
  end

  defp recorded(report, stream, recreated?) do
    _count = Store.record_stream(stream.id, stream.status, recreated?)
    %{report | stream_up: stream.status == :enabled}
  end

  defp gauges(report) do
    unpaired = Store.stalled(@stalled_runs)
    up = if report.stream_up, do: 1, else: 0
    measurements = %{unpaired_access_environments: unpaired, stream_up: up}
    :telemetry.execute([:relay, :access, :pairing], measurements)
    %{report | unpaired_access_environments: unpaired}
  end

  defp finish(report) do
    signals = Enum.reverse(report.signals)
    Enum.each(signals, &log/1)
    %{report | signals: signals}
  end

  defp signal(report, kind, meta), do: %{report | signals: [{kind, meta} | report.signals]}

  defp add(acc, kind, meta), do: %{acc | signals: [{kind, meta} | acc.signals]}

  defp log({:unpaired, meta}) do
    Logger.error("access environment unpaired",
      event: "access.access_environment_unpaired",
      access_tenant_id: meta.tenant,
      access_environment: meta.access_environment,
      runs: meta.runs
    )
  end

  defp log({kind, meta}) do
    level = if kind == :cleared or kind == :stream_recreated, do: :info, else: :warning
    fields = meta |> Map.update(:error, nil, &reason/1) |> Map.reject(&is_nil(elem(&1, 1)))
    Logger.log(level, "access pairing " <> Atom.to_string(kind), Map.to_list(fields))
  end

  defp reason(%Relay.Error{code: code}), do: code
  defp reason({:refused, status, code}), do: "Access answered #{status} #{code}"
  defp reason({:network, %Relay.Error{code: code}}), do: code
  defp reason({:invalid, message}), do: message
  defp reason(other), do: inspect(other)

  defp now_ms, do: DateTime.to_unix(Relay.Clock.utc_now(), :millisecond)
end
