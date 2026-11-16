defmodule Relay.Workflow.Digest do
  @moduledoc """
  Digest windows (WF-26 … WF-31, INV-3, INV-32). A window is a row and a timer: an event is first written as an item of the open window of its key, then the window's firing time is planned and its timer job queued, in the caller's transaction, so an accepted event is never only in a job argument and never lost (WF-27). The key is the tenant's grouping key, scoped by the workflow step, and always per recipient; the database keeps one open window per recipient and key (`UNIQUE`, INV-12). A window holds identifiers only; the activities' content stays in the event records.

  `add/2` answers the role of the caller's run: `:anchor` (the first digested item; the run waits and sends the digest when the window fires), `:folded` (the item is in the digest; the run ends here) or `:sent_alone` (the first event of a `leading: immediate` window; the run sends it now and the window collects the repeats). The timer job, `Relay.Workflow.Digest.Timer`, fires the window when it is due; an early wake-up reschedules itself, and the sweep (`Relay.Workflow.Digest.Sweep`) plans and fires open windows whose timer was lost. Firing never sends an empty digest; a window of one activity hands over the anchor notification itself for its singular template; two or more hand over the digest render data, cumulative since the recipient last read the key (WF-29). The outcome goes to the configured sink (`Relay.Workflow.Digest.Sink`) in the closing transaction. A read signal cancels the pending windows of a notification's keys (WF-27).

  The same windows carry the density threshold (WF-30), routing a recipient's further events of a category into a window once the threshold is passed, the morning burst guard (PC-46), holding a recipient's `social` and `marketing` deliveries released at the end of quiet hours in one window released with deterministic jitter, and the `digest` fate of the frequency cap (PC-50, PC-58 (6)), holding a recipient's capped deliveries of a category and channel in one window released when a slot frees. The policy lattice holds deliveries in these windows (`held` in the answer of `add/2` is true when the caller's delivery waits in an open window); their outcomes go to the configured release (`config :relay, Relay.Workflow.Digest, release: Module`, the same `digest_ready/2` callback) with the window's `origin` and every held delivery under `deliveries`, oldest first, instead of the run sink.
  """

  alias Relay.Scope
  alias Relay.Workflow.Digest.Store
  alias Relay.Workflow.Digest.Timer
  alias Relay.Workflow.Digest.Window
  alias Relay.Workflow.Throttle

  @due_batch 100
  @quiet_classes ~w(social marketing)
  @held_origins ~w(density quiet_hours frequency)

  @type role :: :anchor | :folded | :sent_alone
  @type added :: %{
          role: role(),
          window_id: Relay.Id.t(),
          generation: pos_integer(),
          fire_at: DateTime.t() | nil,
          held: boolean()
        }

  # WF-26
  # WF-27
  # WF-28
  # INV-3
  # INV-12
  @doc """
  Adds an event to its digest window inside the caller's scoped transaction. `attrs`: `:recipient_id`, `:notification_id`, `:message_class`, `:scope_ref` (the workflow and step the key belongs to), `:key` (the tenant's rendered grouping key), `:step` (the step's digest fields) or `:config` (a `Relay.Workflow.Digest.Window` configuration), and optionally `:delivery_id`, `:actor` (the activity's actor reference, kept as a digest only), `:time_zone` (the recipient's IANA zone, required for a `scheduled` window) and `:origin` (`"step"`, `"density"` or `"quiet_hours"`).
  """
  @spec add(Scope.t(), map()) :: {:ok, added()} | {:error, Relay.Error.t()}
  def add(%Scope{} = scope, attrs) do
    with :ok <- digestible(attrs.message_class),
         {:ok, config} <- config(attrs),
         {:ok, zone} <- zone(config, Map.get(attrs, :time_zone)) do
      written = Store.add(row(attrs, config, zone))
      added(scope, written, attrs, config, zone)
    end
  end

  # WF-30
  @doc """
  Routes an event into a digest window once the recipient's density threshold is passed, inside the caller's scoped transaction. `attrs` carries `:threshold` (`%{"limit" => n, "window" => duration}`), `:category`, optionally `:device` (the device reference the threshold counts per), optionally `:channel` (the window is then the category's on that channel), `:ref` (the event's unique reference, so a retry counts once) and the attributes of `add/2` for the window. Below the threshold the event is not digested: `{:ok, :under}`.
  """
  @spec density(Scope.t(), map()) :: {:ok, :under | added()} | {:error, Relay.Error.t()}
  def density(%Scope{} = scope, attrs) do
    parts = [id_text(attrs.recipient_id), attrs.category, Map.get(attrs, :device)]

    with :ok <- digestible(attrs.message_class),
         {:ok, hit} <- Throttle.count(scope, {"density", parts}, attrs.ref, attrs.threshold) do
      case hit.outcome do
        :allowed -> {:ok, :under}
        :limited -> add(scope, density_attrs(attrs))
      end
    end
  end

  # PC-46
  # WF-42
  @doc """
  Holds a `social` or `marketing` delivery that the end of the recipient's quiet hours releases in one window released at `:release_at` (see `Relay.Workflow.Digest.Window.release_at/5` for the jittered time), inside the caller's scoped transaction. `attrs`: `:recipient_id`, `:notification_id`, `:delivery_id`, `:message_class`, `:category`, `:channel`, `:release_at`. Other classes answer `{:ok, :not_applicable}`.
  """
  @spec quiet_hours(Scope.t(), map()) ::
          {:ok, :not_applicable | added()} | {:error, Relay.Error.t()}
  def quiet_hours(%Scope{} = scope, %{message_class: class} = attrs) do
    if to_string(class) in @quiet_classes,
      do: add(scope, quiet_attrs(attrs)),
      else: {:ok, :not_applicable}
  end

  # PC-50
  # PC-58 (6)
  @doc """
  Holds a delivery that the frequency cap meets with its `digest` fate in the window of the recipient's category and channel, released at `:release_at` when the window opens (the jittered time a slot frees), inside the caller's scoped transaction. `attrs`: `:recipient_id`, `:notification_id`, `:delivery_id`, `:message_class`, `:category`, `:channel`, `:release_at`.
  """
  @spec frequency(Scope.t(), map()) :: {:ok, added()} | {:error, Relay.Error.t()}
  def frequency(%Scope{} = scope, attrs), do: add(scope, frequency_attrs(attrs))

  # WF-29
  # PC-46
  # WF-30
  @doc "The digest render data of a delivery that anchors a fired window of the policy lattice (density, quiet hours or frequency) of two or more activities, inside the caller's scoped transaction; `nil` for any other delivery."
  @spec held_render(Relay.Id.t()) :: map() | nil
  def held_render(delivery_id) do
    case Store.anchored(delivery_id, @held_origins) do
      %{cumulative_count: count} = window when count > 1 ->
        Window.render(window, Store.items(window, 50))

      _none ->
        nil
    end
  end

  # WF-27
  # WF-29
  # T-24
  @doc "Fires a window in its own transaction: plans an unplanned one, reschedules one that is not due, and closes a due one, handing its outcome to the sink."
  @spec fire(Scope.t(), Relay.Id.t()) :: {:ok, term()} | {:error, term()}
  def fire(%Scope{} = scope, window_id) do
    Store.in_scope(scope, fn _status ->
      case Store.window(window_id) do
        nil -> :not_found
        %{state: "open", fire_at: nil} = window -> replan(scope, window)
        %{state: "open"} -> close(scope, window_id)
        _closed -> :not_open
      end
    end)
  end

  # WF-27
  @doc "Applies a recipient's read signal for a notification in its own transaction: the pending windows of its keys are cancelled, each cancellation handed to the sink, and the fired ones are marked read so the next digest starts its total again."
  @spec read(Scope.t(), Relay.Id.t(), Relay.Id.t()) ::
          {:ok, [{Relay.Id.t(), :cancelled | :read}]} | {:error, term()}
  def read(%Scope{} = scope, recipient_id, notification_id) do
    Store.in_scope(scope, fn _status -> read_in_scope(scope, recipient_id, notification_id) end)
  end

  # WF-27
  @doc "Applies a recipient's read signal for a notification inside the caller's transaction scoped to `scope`; see `read/3`."
  @spec read_in_scope(Scope.t(), Relay.Id.t(), Relay.Id.t()) :: [{Relay.Id.t(), atom()}]
  def read_in_scope(%Scope{} = scope, recipient_id, notification_id) do
    changed = Store.read(recipient_id, notification_id)

    for {window_id, :cancelled} <- changed,
        do: :ok = sink(scope, {:cancelled, info(window_id)})

    changed
  end

  # T-24
  # TN-8
  @doc "Fires every window of a scope that is due or has no timer; used by the sweep and the virtual clock tick."
  @spec run_due(Scope.t()) :: :ok | {:error, term()}
  def run_due(%Scope{} = scope) do
    case Store.in_scope(scope, fn _status -> Store.due(@due_batch) end) do
      {:ok, due} ->
        Enum.each(due, &fire(scope, &1))
        if length(due) == @due_batch, do: run_due(scope), else: :ok

      {:error, _reason} = error ->
        error
    end
  end

  # WF-27
  @doc "Fires the due windows of every scope that has one."
  @spec sweep(pos_integer()) :: non_neg_integer()
  def sweep(limit \\ 100) do
    limit
    |> Store.due_scopes()
    |> Enum.count(fn {tenant_id, environment} ->
      with {:ok, scope} <- Scope.new(tenant_id, environment),
           :ok <- run_due(scope) do
        true
      else
        _failed -> false
      end
    end)
  end

  # WF-26
  @doc "The key digest of a window: SHA-256 over the deterministic CBOR of its origin, scope reference and the tenant's key."
  @spec window_key(String.t(), String.t(), String.t()) :: <<_::256>>
  def window_key(origin, scope_ref, key) when is_binary(key) do
    canonical = Relay.Canonical.encode!(["relay.digest_window.v1", origin, scope_ref, key])
    :crypto.hash(:sha256, canonical)
  end

  defp digestible(class) do
    if Window.exempt?(class),
      do: {:error, Relay.Error.new(:digest_exempt_class, "this message class is not digested")},
      else: :ok
  end

  defp config(%{config: %{mode: _mode} = config}), do: {:ok, config}

  defp config(%{step: step}) do
    case Window.config(step) do
      {:ok, config} -> {:ok, config}
      {:error, errors} -> {:error, invalid(errors)}
    end
  end

  defp zone(%{mode: :scheduled}, nil), do: {:error, invalid_zone()}

  defp zone(_config, nil), do: {:ok, nil}

  defp zone(_config, zone) do
    case Relay.TimeZone.new(zone) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, _error} -> {:error, invalid_zone()}
    end
  end

  defp row(attrs, config, zone) do
    origin = Map.get(attrs, :origin, "step")

    %{
      window_id: Relay.Id.generate(),
      item_id: Relay.Id.generate(),
      recipient_id: attrs.recipient_id,
      window_key: window_key(origin, attrs.scope_ref, attrs.key),
      origin: origin,
      config: config,
      time_zone: zone,
      max_open_ms: Window.max_open_ms(),
      notification_id: attrs.notification_id,
      delivery_id: Map.get(attrs, :delivery_id),
      actor_digest: actor(Map.get(attrs, :actor))
    }
  end

  defp added(_scope, %{result: :recipient_not_found}, _attrs, _config, _zone),
    do: {:error, Relay.Error.new(:recipient_not_found, "the recipient does not exist")}

  defp added(scope, %{result: result} = written, attrs, config, zone) do
    fire_at = if result == :exists, do: nil, else: plan(scope, written, config, zone)

    {:ok,
     %{
       role: role(written, attrs.notification_id),
       window_id: written.window_id,
       generation: written.generation,
       fire_at: fire_at || pending_at(written),
       held: held?(written, Map.get(attrs, :delivery_id))
     }}
  end

  defp pending_at(%{result: :exists, window_id: window_id}) do
    case Store.window(window_id) do
      %{state: "open", fire_at: at, deadline_at: deadline} -> at || deadline
      _closed -> nil
    end
  end

  defp pending_at(_written), do: nil

  defp held?(_written, nil), do: false
  defp held?(%{sent_alone: true}, _delivery_id), do: false
  defp held?(%{result: :exists, window_id: id}, delivery_id), do: Store.holds?(id, delivery_id)
  defp held?(_written, _delivery_id), do: true

  defp role(%{sent_alone: true}, _notification_id), do: :sent_alone

  defp role(%{window_id: window_id}, notification_id) do
    case Store.anchor(window_id) do
      %{notification_id: ^notification_id} -> :anchor
      _other -> :folded
    end
  end

  defp plan(scope, window, config, zone) do
    at = Window.fire_at(config, window, zone)

    case Store.plan(window.window_id, at) do
      {:schedule, fire_at} ->
        :ok = insert_timer(scope, window.window_id, fire_at)
        fire_at

      {_kept, fire_at} ->
        fire_at
    end
  end

  defp replan(scope, window) do
    config = %{
      mode: String.to_existing_atom(window.mode),
      leading: String.to_existing_atom(window.leading),
      debounce_ms: window.debounce_ms,
      max_wait_ms: window.max_wait_ms,
      schedule: window.schedule,
      max_items: window.max_items,
      release_at: window.release_at
    }

    _fire_at = plan(scope, Map.put(window, :window_id, window.id), config, window.time_zone)
    :planned
  end

  defp close(scope, window_id) do
    case Store.fire(window_id) do
      %{result: :not_due, next_at: at} ->
        :ok = insert_timer(scope, window_id, at)
        :not_due

      %{result: :fired} ->
        outcome = outcome(window_id)
        :ok = sink(scope, outcome)
        outcome

      %{result: result} ->
        result
    end
  end

  defp outcome(window_id) do
    window = Store.window(window_id)
    info = info(window_id, window)

    if window.cumulative_count == 1,
      do: {:single, info},
      else: {:digest, Map.put(info, :render, Window.render(window, Store.items(window, 50)))}
  end

  defp info(window_id), do: info(window_id, Store.window(window_id))

  defp info(window_id, window) do
    anchor = Store.anchor(window_id) || %{notification_id: nil, delivery_id: nil}
    info = Map.put(anchor, :window_id, window_id)

    case window do
      %{origin: origin} when origin in @held_origins ->
        Map.merge(info, %{origin: origin, deliveries: Store.deliveries(window_id)})

      _step ->
        info
    end
  end

  defp sink(scope, {_kind, info} = outcome) do
    key = if Map.has_key?(info, :origin), do: :release, else: :sink

    case :relay |> Application.get_env(__MODULE__, []) |> Keyword.get(key) do
      nil -> :ok
      module -> module.digest_ready(scope, outcome)
    end
  end

  defp insert_timer(scope, window_id, business_at) do
    args =
      scope
      |> Scope.to_job_args()
      |> Map.put("window_id", Relay.Id.to_string(window_id))

    Store.insert_job!(Timer.new(args, scheduled_at: Relay.Clock.wall_time(scope, business_at)))
  end

  defp quiet_attrs(%{release_at: at} = attrs) do
    key = Enum.join([attrs.category, attrs.channel, DateTime.to_iso8601(at)], "/")
    extra = %{origin: "quiet_hours", scope_ref: "quiet_hours", key: key}
    attrs |> Map.merge(extra) |> Map.put(:config, Window.release(at))
  end

  defp frequency_attrs(%{release_at: at} = attrs) do
    key = Enum.join([attrs.category, attrs.channel], "/")
    extra = %{origin: "frequency", scope_ref: "frequency", key: key}
    attrs |> Map.merge(extra) |> Map.put(:config, Window.release(at))
  end

  defp density_attrs(attrs) do
    key = Enum.join([attrs.category | List.wrap(Map.get(attrs, :channel))], "/")
    Map.merge(attrs, %{origin: "density", scope_ref: "density", key: key})
  end

  defp id_text(<<_::128>> = id), do: Relay.Id.to_string(id)

  defp actor(nil), do: nil

  defp actor(ref) when is_binary(ref),
    do: :crypto.hash(:sha256, Relay.Canonical.encode!(["relay.digest_actor.v1", ref]))

  defp invalid(errors) do
    details = Enum.map(errors, &stringify/1)
    Relay.Error.new(:validation_failed, "the digest step is not valid", %{errors: details})
  end

  defp stringify(error), do: Map.new(error, fn {key, value} -> {Atom.to_string(key), value} end)

  defp invalid_zone,
    do: Relay.Error.new(:validation_failed, "a scheduled digest needs the recipient's time zone")
end
