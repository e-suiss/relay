defmodule Relay.Iys.Sync do
  @moduledoc """
  The İYS read path (PC-32, PC-33, PC-62, OP-42): it keeps the permission cache (`Relay.Iys.Permissions`) equal to what İYS holds. The official İYS document offers no notification of a rejection to the service provider, so a rejection is received by pulling.

  `run/2` is one run for a scope, brand by brand:

    * **Pull.** When the published pull interval passed, the consent movements are read from the brand's cursor, first those recipients made at İYS (`IYS`), then those of the service provider (`HS`), page by page, and each page is written to the cache with its cursor in one transaction. A pull that reached the end of both is the brand's last successful synchronisation. The first pull of a brand, and a pull after a gap longer than İYS's window of movements (seven days) or with a cursor İYS no longer accepts, is a full synchronisation: the cursors start over at the beginning of the window, and after a gap every approval the cache held before it has to be verified again before it counts (`Relay.Iys.Permissions.status/4`).
    * **Verification.** Approvals waiting for that, and permissions written from an upload that no pull reported once İYS's blind spot of the last hour and two pull intervals passed, are read again from İYS one address at a time, under the published number per run.
    * **Rejections.** A rejection that came from İYS is applied in Relay as a refusal notice with source `iys` for every active recipient that has the address: the consent copy gets its `revoked` row and the tenant its `consent.revoked` event. It is not written back to İYS. The cache already stops the brand's marketing to the address from the moment the pull committed.
    * **Reconciliation.** At the published interval the uploads, the cache and İYS are compared: a confirmed upload the cache does not hold and a permission no pull reported are counted as drift, and the distinct addresses of the brand are counted against the direct access threshold of a brand that connects through an integrator (PC-62).

  `stale_check/2` reads no network: it compares the age of each brand's last successful synchronisation with the warning and the stop age and announces a change to the tenant as `iys.copy_stale` (PC-33). `status/2` is what the operator sees.
  """

  require Logger

  alias Relay.Iys
  alias Relay.Iys.Client
  alias Relay.Iys.Consent
  alias Relay.Iys.Permissions
  alias Relay.Iys.Store
  alias Relay.Scope

  @feeds ["IYS", "HS"]
  @cursors %{"IYS" => "cursor_iys", "HS" => "cursor_hs"}
  @blocked_s 1_800
  @slack_s 30
  @refusal_rows 200

  @type report :: %{
          brand_code: pos_integer(),
          pull: :ok | :failed | :not_due,
          applied: non_neg_integer(),
          verified: non_neg_integer(),
          refusals: non_neg_integer(),
          reconciled: boolean()
        }

  # PC-32
  # OP-42
  @doc "Runs the read path of a scope once; see the module documentation. Runs outside any transaction."
  @spec run(Scope.t(), DateTime.t()) :: Iys.result([report()])
  def run(%Scope{} = scope, %DateTime{} = now) do
    case read(scope) do
      {:ok, {%{} = config, brands}} ->
        conn = connection(scope, config, now)
        {:ok, Enum.map(brands, &brand(%{scope: scope, config: config, conn: conn, now: now}, &1))}

      {:ok, {nil, _brands}} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read(scope),
    do: Store.in_scope(scope, fn _status -> {Store.config(), Store.sync_states()} end)

  defp connection(scope, config, now) do
    with :ok <- usable(config, now), do: Iys.connection(scope, config)
  end

  defp usable(%{"blocked_at" => %DateTime{} = at}, now) do
    if DateTime.diff(now, at, :second) < @blocked_s, do: {:error, :blocked}, else: :ok
  end

  defp usable(_config, _now), do: :ok

  defp brand(ctx, brand) do
    ctx = Map.put(ctx, :brand, brand)

    pulled =
      if due?(brand["last_attempt_at"], "pull_interval", ctx.now),
        do: pull(ctx),
        else: %{pull: :not_due, applied: 0}

    verified = verify(ctx)
    refusals = refusals(ctx)

    Map.merge(pulled, %{
      brand_code: brand["brand_code"],
      verified: verified,
      refusals: refusals,
      reconciled: reconcile(ctx)
    })
  end

  defp due?(nil, _limit, _now), do: true

  defp due?(%DateTime{} = last, limit, now),
    do: DateTime.diff(now, last, :second) >= Relay.Limits.seconds!(["iys", limit]) - @slack_s

  # PC-32
  defp pull(%{conn: {:error, reason}} = ctx),
    do: finished(ctx, {:error, Atom.to_string(reason), 0})

  defp pull(%{conn: {:ok, conn}} = ctx) do
    ctx = %{ctx | conn: conn, brand: started(ctx)}
    budget = Iys.limit("pull_pages_per_run")

    result =
      Enum.reduce_while(@feeds, {:ok, 0, budget}, fn feed, {:ok, applied, pages} ->
        cursor = ctx.brand[Map.fetch!(@cursors, feed)]

        case feed(ctx, feed, cursor, pages) do
          {:ok, count, left} -> {:cont, {:ok, applied + count, left}}
          {:error, code, count} -> {:halt, {:error, code, applied + count}}
        end
      end)

    finished(ctx, result)
  end

  defp started(%{brand: brand} = ctx) do
    case mode(brand, ctx.now) do
      :incremental ->
        brand

      {:full, floor?} ->
        record(ctx, %{"full_sync" => "started", "floor" => floor?})

        Map.merge(brand, %{
          "cursor_iys" => nil,
          "cursor_hs" => nil,
          "full_sync_started_at" => ctx.now
        })
    end
  end

  defp mode(%{"full_sync_started_at" => %DateTime{}}, _now), do: :incremental
  defp mode(%{"last_pull_at" => nil}, _now), do: {:full, false}

  defp mode(%{"last_pull_at" => %DateTime{} = last}, now) do
    window = Relay.Limits.seconds!(["iys", "changes_window"])
    if DateTime.diff(now, last, :second) > window, do: {:full, true}, else: :incremental
  end

  defp feed(_ctx, _feed, _cursor, pages) when pages <= 0, do: {:error, "page_budget", 0}

  defp feed(ctx, feed, cursor, pages) do
    size = Iys.limit("changes_page_size")
    opts = [after: cursor, limit: size, source: feed]

    case Client.changes(ctx.conn, ctx.brand["brand_code"], opts) do
      {:ok, %{list: []}} -> {:ok, 0, pages}
      {:ok, %{after: next, list: list}} -> page(ctx, feed, {next, list}, pages, size)
      {:error, failure} -> {:error, code(failure, cursor), 0}
    end
  end

  defp page(ctx, feed, {next, list}, pages, size) do
    with {:ok, movements} <- Permissions.movements(ctx.scope, list),
         {:ok, count} <- written(ctx, feed, next, movements) do
      if length(list) < size or not is_binary(next),
        do: {:ok, count, pages - 1},
        else: following(feed(ctx, feed, next, pages - 1), count)
    else
      _failed -> {:error, "apply_failed", 0}
    end
  end

  defp following({:ok, count, left}, before), do: {:ok, before + count, left}
  defp following({:error, code, count}, before), do: {:error, code, before + count}

  defp written(ctx, feed, next, movements) do
    work = fn _status ->
      Store.permissions_apply(ctx.brand["id"], "pull", feed, next, movements, ctx.now)
    end

    case Store.in_scope(ctx.scope, work) do
      {:ok, {:applied, count}} -> {:ok, count}
      _failed -> :error
    end
  end

  defp code(%{class: :rejected}, cursor) when is_binary(cursor), do: "cursor_rejected"
  defp code(%{code: code}, _cursor) when is_binary(code), do: code
  defp code(%{status: status}, _cursor) when is_integer(status), do: "http_#{status}"
  defp code(_transport, _cursor), do: "unavailable"

  defp finished(ctx, {:ok, applied, _left}) do
    record(ctx, succeeded(ctx.brand["full_sync_started_at"]))
    :telemetry.execute([:relay, :iys, :sync, :pull], %{count: 1}, %{result: "ok"})
    %{pull: :ok, applied: applied}
  end

  defp finished(ctx, {:error, code, applied}) do
    failed = %{"pull" => "failed", "error_code" => code}
    restart = %{"full_sync" => "started", "floor" => true}
    record(ctx, if(code == "cursor_rejected", do: Map.merge(failed, restart), else: failed))
    :telemetry.execute([:relay, :iys, :sync, :pull], %{count: 1}, %{result: "failed"})
    Logger.warning("an İYS pull did not finish", code: code)
    %{pull: :failed, applied: applied}
  end

  defp succeeded(%DateTime{}), do: %{"pull" => "ok", "full_sync" => "finished"}
  defp succeeded(_none), do: %{"pull" => "ok"}

  defp record(ctx, observation) do
    work = fn _status -> Store.sync_record(ctx.brand["id"], observation, ctx.now) end
    {:ok, :recorded} = Store.in_scope(ctx.scope, work)
    :ok
  end

  # PC-32
  # OP-42
  defp verify(%{conn: {:ok, conn}} = ctx) do
    before = DateTime.add(ctx.now, -unpulled_after_s(), :second)
    limit = Iys.limit("verifications_per_run")
    floor = ctx.brand["full_sync_floor_at"]
    read = fn _status -> Store.unverified(ctx.brand["id"], floor, before, limit) end
    {:ok, rows} = Store.in_scope(ctx.scope, read)

    Enum.reduce_while(rows, 0, fn row, count ->
      case Permissions.check(ctx.scope, conn, ctx.brand, row, ctx.now) do
        :ok -> {:cont, count + 1}
        :skip -> {:cont, count}
        {:error, _failure} -> {:halt, count}
      end
    end)
  end

  defp verify(_ctx), do: 0

  defp unpulled_after_s do
    Relay.Limits.seconds!(["iys", "changes_blind_spot"]) +
      2 * Relay.Limits.seconds!(["iys", "pull_interval"])
  end

  # PC-32
  # PC-38
  defp refusals(ctx) do
    read = fn _status -> Store.pending_refusals(ctx.brand["id"], @refusal_rows) end
    {:ok, rows} = Store.in_scope(ctx.scope, read)
    Enum.count(rows, &refused?(ctx, &1))
  end

  defp refused?(ctx, row) do
    results = Enum.map(row["recipient_ids"], &refuse(ctx, row, &1))

    mark =
      cond do
        results == [] -> "refusal_unmatched"
        Enum.all?(results, &(&1 == :ok)) -> "refusal_applied"
        true -> nil
      end

    if mark, do: mark(ctx, row["id"], mark)
    mark == "refusal_applied"
  end

  defp refuse(ctx, row, recipient_id) do
    reference = row["transaction_ref"] || Relay.Id.to_string(row["id"])

    attrs = %{
      recipient_id: recipient_id,
      channel: Consent.channel(row["consent_type"]),
      source: "iys",
      ref: "iys:" <> reference <> ":" <> Relay.Id.to_string(recipient_id),
      brand_subtenant_id: ctx.brand["subtenant_id"],
      occurred_at: row["consent_at"] || row["registered_at"] || ctx.now
    }

    Iys.runtime().refuse(ctx.scope, attrs)
  end

  defp mark(ctx, id, mark) do
    work = fn _status -> Store.permission_mark(id, mark, ctx.now) end
    {:ok, _marked} = Store.in_scope(ctx.scope, work)
    :telemetry.execute([:relay, :iys, :sync, :rejection], %{count: 1}, %{result: mark})
  end

  # OP-42
  # PC-62
  defp reconcile(%{brand: brand} = ctx),
    do: due?(brand["reconciled_at"], "reconcile_interval", ctx.now) and reconciled(ctx)

  defp reconciled(%{brand: brand} = ctx) do
    before = DateTime.add(ctx.now, -unpulled_after_s(), :second)

    work = fn _status ->
      counts = Store.reconciliation(brand["id"], brand["full_sync_floor_at"], before)
      state = address_state(ctx.config, counts["addresses"])

      observation = %{
        "drift_count" => counts["drift"],
        "address_count" => counts["addresses"],
        "address_state" => state
      }

      :recorded = Store.sync_record(brand["id"], observation, ctx.now)
      {counts, state}
    end

    {:ok, {counts, state}} = Store.in_scope(ctx.scope, work)

    measurements = %{
      drift: counts["drift"],
      unverified: counts["unverified"],
      addresses: counts["addresses"]
    }

    :telemetry.execute([:relay, :iys, :sync, :reconciled], measurements, %{})
    if counts["drift"] > 0, do: Logger.warning("the İYS reconciliation found drift")
    threshold(brand, state)
    true
  end

  # PC-62
  @doc "The state of a brand against the direct access threshold: `reached` at the published number of distinct addresses, `warning` from the published percentage of it, otherwise `ok`. Only a brand that connects through an integrator is measured."
  @spec address_state(map(), non_neg_integer()) :: String.t()
  def address_state(%{"mode" => "integrator"}, addresses) when is_integer(addresses) do
    threshold = Iys.limit("direct_access_threshold")
    percent = Iys.limit("direct_access_warning_percent")

    cond do
      addresses >= threshold -> "reached"
      addresses * 100 >= threshold * percent -> "warning"
      true -> "ok"
    end
  end

  def address_state(_own, _addresses), do: "ok"

  defp threshold(brand, state) do
    if state != "ok" and state != (brand["address_state"] || "ok") do
      :telemetry.execute([:relay, :iys, :address_threshold], %{count: 1}, %{state: state})
      Logger.warning("an İYS brand nears the direct access threshold", state: state)
    end

    :ok
  end

  # PC-33
  # INV-43
  @doc "Compares the age of each brand's last successful synchronisation at `now` with the warning and the stop age and announces a change of a brand's state to the tenant; answers how many brands changed. Reads no network."
  @spec stale_check(Scope.t(), DateTime.t()) :: Iys.result(non_neg_integer())
  def stale_check(%Scope{} = scope, %DateTime{} = now) do
    work = fn _status -> Enum.count(Store.sync_states(), &stale_changed?(&1, now)) end
    Store.in_scope(scope, work)
  end

  defp stale_changed?(brand, now) do
    state = stale_state(brand, now)
    changed? = state != (brand["stale_state"] || "fresh")
    if changed?, do: stale(brand, state, now)
    changed?
  end

  defp stale(brand, state, now) do
    :recorded = Store.sync_record(brand["id"], %{"stale_state" => state}, now)
    :telemetry.execute([:relay, :iys, :sync, :stale], %{count: 1}, %{state: state})

    if state != "fresh" do
      data = %{
        "brand_code" => brand["brand_code"],
        "state" => state,
        "last_synced_at" => brand["last_pull_at"],
        "observed_at" => now
      }

      Store.event("iys.copy_stale", "iys_brand:" <> Relay.Id.to_string(brand["id"]), data)
    end

    :ok
  end

  @doc "The state of a brand's copy at `now`: `stopped` from the stop age, `warning` from the warning age, otherwise `fresh`. A brand that never synchronised is aged from its creation."
  @spec stale_state(map(), DateTime.t()) :: String.t()
  def stale_state(brand, %DateTime{} = now) do
    age = DateTime.diff(now, brand["last_pull_at"] || brand["created_at"], :second)

    cond do
      age >= Relay.Limits.seconds!(["iys", "stale_stop"]) -> "stopped"
      age >= Relay.Limits.seconds!(["iys", "stale_warning"]) -> "warning"
      true -> "fresh"
    end
  end

  # PC-32
  # PC-33
  # OP-42
  @doc "The synchronisation state of each active brand of the scope at `now`, for the operator: the last successful pull and its age, the last attempt and its error, the instant up to which the copy covers İYS (the pull never sees İYS's last hour), the full synchronisations, the drift the last reconciliation counted and the distinct addresses against the direct access threshold."
  @spec status(Scope.t(), DateTime.t()) :: Iys.result([map()])
  def status(%Scope{} = scope, %DateTime{} = now) do
    blind = Relay.Limits.seconds!(["iys", "changes_blind_spot"])
    work = fn _status -> Enum.map(Store.sync_states(), &described(&1, now, blind)) end
    Store.in_scope(scope, work)
  end

  defp described(brand, now, blind) do
    last = brand["last_pull_at"]

    %{
      brand_code: brand["brand_code"],
      last_pull_at: last,
      cursor_age_seconds: last && DateTime.diff(now, last, :second),
      covered_until: last && DateTime.add(last, -blind, :second),
      blind_spot_seconds: blind,
      last_attempt_at: brand["last_attempt_at"],
      last_error_code: brand["last_error_code"],
      stale_state: stale_state(brand, now),
      full_sync_running: match?(%DateTime{}, brand["full_sync_started_at"]),
      full_sync_floor_at: brand["full_sync_floor_at"],
      last_full_sync_at: brand["last_full_sync_at"],
      reconciled_at: brand["reconciled_at"],
      drift_count: brand["drift_count"] || 0,
      address_count: brand["address_count"] || 0,
      address_state: brand["address_state"] || "ok"
    }
  end
end
