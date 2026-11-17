defmodule Relay.Iys.Uploads do
  @moduledoc """
  The İYS write path (PC-30, PC-28, E-21).

  `write/2` opens the upload of a consent movement: the İYS type, source and recipient type are mapped, an approval gets the deadline of its three business days (`Relay.Iys.Calendar`), the address is sealed and indexed outside the transaction, and the upload row and its job commit together. Nothing is sent to İYS here.

  `run/2` is one attempt of the job. The upload is claimed in its own transaction, which keeps the movements of one recipient, brand and type in order and apart: an earlier open movement of the same key, or one İYS recorded less than two seconds ago, makes the job come back. The request is made outside any transaction. A `200` only marks the upload `uploaded`; it is `confirmed`, and the consent copy gets its `active` or `revoked` row with the İYS transaction identifier, after the status was read back from İYS and agrees. What İYS answers decides the rest:

    * a confirmed movement is also written to the permission cache in the transaction that settles it (`Relay.Iys.Permissions.confirmed/3`), so the lattice reads a rejection Relay wrote before the next pull reports it;
    * the status is already the one sent (`H174`): read back and confirm;
    * a refusal for a recipient İYS holds no record of (`H175`): `skipped`, there is nothing to refuse;
    * a consent older than three business days (`H467`), or a deadline that passed before the upload: `expired`, announced as `iys.consent_expired`;
    * any other refusal of the request, a movement that fails the local checks, or a status that still disagrees after the published number of read-backs: `failed`, kept for the operator and announced as `iys.upload_failed`;
    * no access (`401`, `403`), a brand the integrator is not authorised to write, a limit or an unavailable service: the upload stays open and the job comes back later; nothing is sent for a configuration İYS refused in the last half hour.

  `sweep/2` expires the approvals whose deadline passed and queues again the open uploads that no attempt touched, so a lost job does not leave a consent waiting.
  """

  require Logger

  alias Relay.Iys
  alias Relay.Iys.Calendar
  alias Relay.Iys.Client
  alias Relay.Iys.Consent
  alias Relay.Iys.Permissions
  alias Relay.Iys.Store
  alias Relay.Scope

  @claim_s 120
  @busy_s 5
  @blocked_s 1_800
  @retry_s 30
  @retry_max_s 900
  @idle_s 3_600
  @sweep_rows 500
  @unmapped "UNMAPPED"
  @access %{"MESAJ" => "message_access", "ARAMA" => "call_access", "EPOSTA" => "email_access"}

  @type outcome :: :done | {:snooze, pos_integer()} | {:error, term()}

  # PC-30
  # E-21
  @doc "Opens the upload of a movement; see `Relay.Iys.write/2`."
  @spec write(Scope.t(), Iys.movement()) :: Iys.result(Iys.written())
  def write(%Scope{} = scope, %{channel: channel} = movement) do
    case Consent.type(channel) do
      {:ok, type} -> opened(scope, movement, type)
      :out_of_scope -> {:ok, :out_of_scope}
    end
  end

  defp opened(scope, movement, type) do
    runtime = Iys.runtime()
    address = Consent.recipient(type, movement.address)

    with true <- Iys.configured?(scope),
         {:ok, deadline} <- deadline(runtime, movement),
         {:ok, [index | _older]} <- runtime.digests(scope, movement.channel, address),
         {:ok, sealed} <- runtime.seal(scope, address) do
      upload = upload(movement, type, deadline)
      commit(scope, runtime, upload, sealed, index)
    else
      false -> {:ok, :not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  # PC-31
  # PC-60
  defp deadline(_runtime, %{status: :rejection}), do: {:ok, nil}

  defp deadline(runtime, %{status: :approval, occurred_at: at}) do
    with {:ok, calendar} <- runtime.calendar() do
      {deadline, reach} = Calendar.deadline(calendar, at)
      if reach == :beyond_coverage, do: beyond_coverage(calendar)
      {:ok, deadline}
    end
  end

  defp beyond_coverage(calendar) do
    :telemetry.execute([:relay, :iys, :calendar, :beyond_coverage], %{count: 1}, %{})

    Logger.warning("an İYS deadline was counted beyond the business calendar",
      coverage_end: Date.to_iso8601(calendar.coverage_end)
    )
  end

  defp upload(movement, type, deadline) do
    source =
      case Consent.source(movement.source) do
        {:ok, source} -> source
        :error -> @unmapped
      end

    base = %{
      "consent_type" => type,
      "consent_status" => if(movement.status == :approval, do: "ONAY", else: "RET"),
      "recipient_type" => Consent.recipient_type(Map.get(movement, :recipient_type)),
      "source" => source,
      "origin" => Atom.to_string(movement.origin),
      "consent_at" => movement.occurred_at,
      "recipient_id" => text(Map.get(movement, :recipient_id)),
      "consent_id" => text(Map.get(movement, :consent_id)),
      "deadline_at" => deadline
    }

    Map.merge(base, brand(movement))
  end

  defp brand(%{brand_code: code}) when is_integer(code), do: %{"brand_code" => code}

  defp brand(movement),
    do: %{"brand_subtenant_id" => text(Map.get(movement, :brand_subtenant_id))}

  defp text(<<_::128>> = id), do: Relay.Id.to_string(id)
  defp text(_none), do: nil

  defp commit(scope, runtime, upload, sealed, index) do
    now = Relay.Clock.utc_now()
    priority = if upload["consent_status"] == "RET", do: 0, else: 2

    work = fn _status ->
      case Store.upload_enqueue(Relay.Id.generate(), upload, sealed, index, now) do
        {:queued, id} -> queued(runtime.enqueue(scope, id, priority))
        {:brand_not_mapped, id} -> unmapped(id, now)
        {result, _id} -> result
      end
    end

    Store.in_scope(scope, work)
  end

  defp queued(:ok), do: :queued
  defp queued({:error, reason}), do: Store.rollback(reason)

  defp unmapped(id, now) do
    failed(Store.upload(id), "brand_not_mapped", now)
    :brand_not_mapped
  end

  # PC-30
  @doc "Runs one attempt of an upload; see the module documentation."
  @spec run(Scope.t(), Relay.Id.t()) :: outcome()
  def run(%Scope{} = scope, <<_::128>> = id) do
    now = Relay.Clock.utc_now()

    claim = fn _status ->
      case Store.upload_claim(id, DateTime.add(now, @claim_s, :second), now) do
        :claimed -> {:claimed, Store.upload(id), Store.config()}
        :overdue -> expire(id, now)
        other -> other
      end
    end

    case Store.in_scope(scope, claim) do
      {:ok, {:claimed, upload, config}} -> attempt(scope, upload, config, now)
      {:ok, :busy} -> {:snooze, @busy_s}
      {:ok, _settled} -> :done
      {:error, reason} -> {:error, reason}
    end
  end

  defp expire(id, now) do
    upload = Store.upload(id)
    detail = %{"error_code" => "deadline_passed"}

    if Store.upload_settle(id, "expired", detail, Relay.Id.generate(), now) == :settled,
      do: expired(upload, now)

    :expired
  end

  defp attempt(scope, upload, config, now) do
    with :ok <- usable(config, now),
         :ok <- authorised(config, upload, now),
         {:ok, conn} <- Iys.connection(scope, config),
         {:ok, consent} <- movement(scope, upload) do
      case Consent.validate(consent, now) do
        :ok -> send_movement(scope, upload, conn, consent)
        {:error, refusal} -> settle(scope, upload, "failed", code(Atom.to_string(refusal)))
      end
    else
      {:wait, seconds, code} ->
        _released = settle(scope, upload, "retry", code(code))
        {:snooze, seconds}

      {:error, _unavailable} ->
        _released = settle(scope, upload, "retry", code("unavailable"))
        {:snooze, backoff(upload)}
    end
  end

  defp usable(nil, _now), do: {:wait, @blocked_s, "not_configured"}

  defp usable(%{"blocked_at" => %DateTime{} = at, "blocked_code" => code}, now) do
    if DateTime.diff(now, at, :second) < @blocked_s, do: {:wait, @blocked_s, code}, else: :ok
  end

  defp usable(_config, _now), do: :ok

  # PC-29
  # E-22
  defp authorised(%{"mode" => "own"}, _upload, _now), do: :ok

  defp authorised(_integrator, upload, now) do
    max_age = Relay.Limits.seconds!(["iys", "authorisation_max_age"])
    access = upload[Map.fetch!(@access, upload["consent_type"])]

    case upload["authorised_at"] do
      %DateTime{} = at when access == "write" ->
        if DateTime.diff(now, at, :second) <= max_age,
          do: :ok,
          else: {:wait, @blocked_s, "authorisation_stale"}

      _unknown_or_no_access ->
        {:wait, @blocked_s, "not_authorised"}
    end
  end

  defp movement(_scope, %{"address_ct" => nil}), do: {:error, :address_cleared}

  defp movement(scope, upload) do
    runtime = Iys.runtime()

    case runtime.open(scope, upload["address_key_id"], upload["address_ct"]) do
      {:ok, address} -> {:ok, consent(upload, Relay.Redacted.expose(address))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp consent(upload, recipient) do
    %{
      recipient: recipient,
      type: upload["consent_type"],
      status: upload["consent_status"],
      recipient_type: upload["recipient_type"],
      source: upload["source"],
      consent_at: upload["consent_at"]
    }
  end

  defp send_movement(scope, %{"state" => "uploaded"} = upload, conn, consent),
    do: read_back(scope, upload, conn, consent)

  defp send_movement(scope, upload, conn, consent) do
    case Client.add_consent(conn, upload["brand_code"], consent) do
      {:ok, added} ->
        detail = %{
          "transaction_ref" => added.transaction_id,
          "registered_at" => added.registered_at,
          "trace_ref" => added.trace
        }

        _uploaded = settle(scope, upload, "uploaded", detail)
        read_back(scope, upload, conn, consent)

      {:error, %{class: :rejected, code: "H174"}} ->
        read_back(scope, upload, conn, consent)

      {:error, failure} ->
        refused(scope, upload, failure)
    end
  end

  # PC-30
  defp read_back(scope, upload, conn, consent) do
    query = %{
      recipient: consent.recipient,
      type: consent.type,
      recipient_type: consent.recipient_type
    }

    case Client.consent_status(conn, upload["brand_code"], query) do
      {:ok, %{status: status} = held} when status == consent.status ->
        detail = %{
          "transaction_ref" => held.transaction_id,
          "registered_at" => held.registered_at
        }

        settle(scope, upload, "confirmed", compact(detail))

      {:ok, _disagrees} ->
        disagrees(scope, upload)

      {:error, failure} ->
        refused(scope, upload, %{failure | class: transient(failure.class)})
    end
  end

  defp transient(:rejected), do: :retry
  defp transient(class), do: class

  defp disagrees(scope, upload) do
    if upload["attempts"] >= Iys.limit("read_back_attempts") do
      settle(scope, upload, "failed", code("readback_mismatch"))
    else
      detail = %{"error_code" => "readback_mismatch", "state" => "pending"}
      _released = settle(scope, upload, "retry", detail)
      {:snooze, backoff(upload)}
    end
  end

  defp refused(scope, %{"consent_status" => "RET"} = upload, %{class: :rejected, code: "H175"}),
    do: settle(scope, upload, "skipped", code("H175"))

  defp refused(scope, upload, %{class: :rejected, code: "H467"} = failure),
    do: settle(scope, upload, "expired", traced(failure))

  defp refused(scope, upload, %{class: :rejected} = failure),
    do: settle(scope, upload, "failed", traced(failure))

  defp refused(scope, upload, %{class: class} = failure)
       when class in [:unauthorised, :forbidden] do
    blocked = failure.code || "http_" <> Integer.to_string(failure.status || 0)
    now = Relay.Clock.utc_now()

    {:ok, _previous} =
      Store.in_scope(scope, fn _status ->
        Store.config_observe(%{"blocked_code" => blocked}, now)
      end)

    :telemetry.execute([:relay, :iys, :connection, :blocked], %{count: 1}, %{code: blocked})
    _released = settle(scope, upload, "retry", traced(failure))
    {:snooze, @blocked_s}
  end

  defp refused(scope, upload, %{class: :rate_limited} = failure) do
    _released = settle(scope, upload, "retry", traced(failure))
    {:snooze, max(failure.retry_after_s || 1, 1)}
  end

  defp refused(scope, upload, failure) do
    _released = settle(scope, upload, "retry", traced(failure))
    {:snooze, backoff(upload)}
  end

  defp backoff(upload) do
    attempts = min(upload["attempts"] || 1, 6)
    min(@retry_s * Integer.pow(2, max(attempts - 1, 0)), @retry_max_s)
  end

  defp traced(failure) do
    code = failure.code || "http_" <> Integer.to_string(failure.status || 0)
    compact(%{"error_code" => code, "trace_ref" => failure.trace})
  end

  defp code(text), do: %{"error_code" => text}

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp settle(scope, upload, outcome, detail) do
    now = Relay.Clock.utc_now()

    work = fn _status ->
      case Store.upload_settle(upload["id"], outcome, detail, Relay.Id.generate(), now) do
        :settled -> announce(upload, outcome, detail, now)
        _already -> :ok
      end
    end

    case Store.in_scope(scope, work) do
      {:ok, _announced} -> :done
      {:error, reason} -> {:error, reason}
    end
  end

  # PC-34
  # WH-15
  defp announce(upload, "failed", detail, now), do: failed(upload, detail["error_code"], now)
  defp announce(upload, "confirmed", detail, now), do: Permissions.confirmed(upload, detail, now)
  defp announce(upload, "expired", _detail, now), do: expired(upload, now)
  defp announce(_upload, _outcome, _detail, _now), do: :ok

  defp failed(upload, error_code, now) do
    data = Map.merge(event(upload), %{"error_code" => error_code, "failed_at" => now})
    :telemetry.execute([:relay, :iys, :upload, :failed], %{count: 1}, %{code: error_code})
    Store.event("iys.upload_failed", stream(upload), data)
  end

  defp expired(%{"consent_status" => "ONAY"} = upload, now) do
    data = Map.merge(event(upload), %{"consent_at" => upload["consent_at"], "expired_at" => now})
    :telemetry.execute([:relay, :iys, :upload, :expired], %{count: 1}, %{})
    Store.event("iys.consent_expired", stream(upload), Map.delete(data, "status"))
  end

  defp expired(_refusal, _now), do: :ok

  defp event(upload) do
    described = Iys.describe(upload)

    %{
      "upload_id" => Relay.ExternalId.encode("iyu", upload["id"]),
      "recipient_id" => recipient(upload["recipient_id"]),
      "brand_code" => upload["brand_code"],
      "channel" => described.channel,
      "status" => described.status
    }
  end

  # PC-34
  @doc "Announces a movement that has no upload; see `Relay.Iys.unwritable/3`."
  @spec unwritable(Scope.t(), map(), String.t()) :: :ok | {:error, term()}
  def unwritable(%Scope{} = scope, %{channel: channel, status: status} = movement, error_code) do
    now = Relay.Clock.utc_now()
    id = Relay.Id.generate()

    data = %{
      "upload_id" => nil,
      "recipient_id" => recipient(Map.get(movement, :recipient_id)),
      "brand_code" => nil,
      "channel" => channel,
      "status" => Atom.to_string(status),
      "error_code" => error_code,
      "failed_at" => now
    }

    :telemetry.execute([:relay, :iys, :upload, :failed], %{count: 1}, %{code: error_code})
    stream = "iys_upload:" <> Relay.Id.to_string(id)

    work = fn _status -> Store.event("iys.upload_failed", stream, data) end

    case Store.in_scope(scope, work) do
      {:ok, :appended} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # PC-34
  @doc "Opens a failed upload again; see `Relay.Iys.retry_upload/5`."
  @spec retry(Scope.t(), Relay.Id.t(), String.t(), binary(), Relay.Actor.t()) ::
          Iys.result({:retried, map()} | :not_found | :not_failed | :not_retryable)
  def retry(%Scope{} = scope, <<_::128>> = id, reason, digest, actor) do
    runtime = Iys.runtime()
    now = Relay.Clock.utc_now()

    work = fn _status ->
      case Store.upload_retry(id, reason, digest, actor, now) do
        :retried -> requeued(scope, runtime, Store.upload(id))
        refused -> refused
      end
    end

    Store.in_scope(scope, work)
  end

  defp requeued(scope, runtime, upload) do
    priority = if upload["consent_status"] == "RET", do: 0, else: 2
    :queued = queued(runtime.enqueue(scope, upload["id"], priority))
    {:retried, upload}
  end

  defp recipient(nil), do: nil
  defp recipient(id), do: Relay.ExternalId.encode("sub", id)

  defp stream(upload), do: "iys_upload:" <> Relay.Id.to_string(upload["id"])

  # PC-30
  # PC-31
  @doc "Expires overdue approvals and queues idle open uploads again; see `Relay.Iys.sweep/2`."
  @spec sweep(Scope.t(), DateTime.t()) :: Iys.result(Iys.swept())
  def sweep(%Scope{} = scope, %DateTime{} = now) do
    runtime = Iys.runtime()
    idle_since = DateTime.add(now, -@idle_s, :second)

    work = fn _status ->
      now
      |> Store.due(idle_since, @sweep_rows)
      |> Enum.reduce(%{expired: 0, queued: 0}, &swept(scope, runtime, &1, now, &2))
    end

    Store.in_scope(scope, work)
  end

  defp swept(_scope, _runtime, %{"overdue" => true, "id" => id}, now, counts) do
    :expired = expire(id, now)
    %{counts | expired: counts.expired + 1}
  end

  defp swept(scope, runtime, %{"id" => id, "consent_status" => status}, _now, counts) do
    priority = if status == "RET", do: 0, else: 2

    case runtime.enqueue(scope, id, priority) do
      :ok -> %{counts | queued: counts.queued + 1}
      {:error, _reason} -> counts
    end
  end
end
