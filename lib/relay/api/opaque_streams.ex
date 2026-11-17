defmodule Relay.Api.OpaqueStreams do
  @moduledoc """
  The opaque payload stream of the realtime channel (IN-37, AG-44, E-53): AG-UI events travel to a subscriber's clients as a stream type of their own. Relay carries the payload as the text it was given. It does not parse it, change it or read it for any decision; the only things Relay knows about an event are its recipient, its size and its position.

  An event is a record in the subscriber's mailbox, the durable record core every stream of that subscriber shares, so it takes the next `(epoch, seq)` of the same stream as the subscriber's inbox, is announced by the same signal and is read with the same cursor: a reader that reconnects continues after the cursor it holds, sees a gap as a gap and is told to resynchronise when its position is no longer in the stream. The payload is sealed under the tenant's data key while it is stored.

  `publish/2` is the server operation that appends an event. The other functions are the stream as a realtime connection reads it (the callbacks of `Relay.Realtime.Source`): they answer from PostgreSQL only.
  """

  @event_type "agui.event"
  @envelope_type "opaque.ag_ui"
  @max_bytes Relay.Limits.fetch!(["realtime", "opaque_payload_max_bytes"])
  @field %{table: "mailbox_records", column: "payload_ct"}

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # IN-37
  # AG-44
  @doc "The envelope type of an AG-UI event on the realtime channel."
  @spec envelope_type() :: String.t()
  def envelope_type, do: @envelope_type

  # AG-44
  # E-53
  # IN-37
  @doc "Appends an AG-UI event to the stream of the subscriber `recipient_id` names. The payload is text of at most the published limit and is stored and delivered as it is. Runs outside any transaction."
  @spec publish(Relay.Scope.t(), map()) :: answer()
  def publish(%Relay.Scope{} = scope, %{"recipient_id" => recipient, "payload" => payload})
      when is_binary(payload) do
    with :ok <- sized(payload),
         {:ok, subscriber_id} <- subscriber(recipient),
         {:ok, mailbox_id} <- mailbox(scope, subscriber_id),
         {:ok, sealed} <- seal(scope, payload),
         {:ok, record} <- append(scope, mailbox_id, payload, sealed) do
      _woken = Relay.Platform.wake_outbox()
      {:ok, {202, [], view(mailbox_id, record)}}
    end
  end

  defp sized(payload) do
    if byte_size(payload) <= @max_bytes do
      :ok
    else
      {:error,
       Relay.Error.new(:payload_too_large, "the payload exceeds #{@max_bytes} bytes", %{
         limit: @max_bytes,
         actual: byte_size(payload),
         limit_name: "opaque_payload_max_bytes"
       })}
    end
  end

  defp subscriber(text) do
    case Relay.ExternalId.decode(text, ["sub"]) do
      {:ok, id} -> {:ok, id}
      {:error, _error} -> {:error, not_found()}
    end
  end

  defp mailbox(scope, subscriber_id) do
    case Relay.Inbox.ensure_mailbox(scope, :subscriber, subscriber_id) do
      {:ok, {code, mailbox_id, _key}} when code in [:created, :exists] -> {:ok, mailbox_id}
      {:ok, :owner_not_found} -> {:error, not_found()}
      {:ok, _inactive} -> {:error, unavailable()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # TN-27
  defp seal(scope, payload) do
    with {:ok, key_id} <- Relay.Tenancy.active_tenant_key(scope, :data),
         {:ok, ct} <- Relay.Tenancy.encrypt_field(field(scope, key_id), payload) do
      {:ok, %{ct: ct, key_id: key_id}}
    else
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp field(scope, key_id) do
    Map.merge(@field, %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: nil,
      retention_class: :delivery_record,
      key_id: key_id
    })
  end

  defp append(scope, mailbox_id, payload, sealed) do
    record = %{
      id: Relay.Id.generate(),
      mailbox_id: mailbox_id,
      kind: :message,
      event_type: @event_type,
      payload_ct: sealed.ct,
      payload_tenant_key_id: sealed.key_id,
      payload_digest: :crypto.hash(:sha256, payload)
    }

    case Relay.Inbox.append(scope, record) do
      {:ok, {:appended, epoch, seq}} -> {:ok, Map.merge(record, %{epoch: epoch, seq: seq})}
      {:ok, :mailbox_not_found} -> {:error, not_found()}
      {:ok, _inactive} -> {:error, not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp view(mailbox_id, record) do
    %{
      "object" => "opaque_event",
      "stream" => "ag_ui",
      "id" => Relay.ExternalId.encode("mbr", record.id),
      "mailbox_id" => Relay.ExternalId.encode("mbx", mailbox_id),
      "cursor" => Relay.Inbox.encode_cursor(%{epoch: record.epoch, seq: record.seq, ann: 0}),
      "payload_digest" => "sha256:" <> Base.encode16(record.payload_digest, case: :lower)
    }
  end

  defp not_found, do: Relay.Error.new(:subscriber_not_found, "no subscriber has this id")
  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})

  # IN-24
  @doc "The signal topic of the subscriber's stream; the stream is the one its inbox uses."
  @spec signal_topic(Relay.Scope.t(), Relay.Id.t()) :: {:ok, String.t()} | {:error, term()}
  def signal_topic(scope, subscriber_id), do: Relay.Inbox.signal_topic(scope, subscriber_id)

  # IN-22
  @doc "The cursor of the stream's head."
  @spec head(Relay.Scope.t(), Relay.Id.t()) :: {:ok, String.t()} | {:error, term()}
  def head(scope, subscriber_id), do: Relay.Inbox.cursor(scope, subscriber_id)

  # IN-26
  @doc "The subscriber's badge counters, which every realtime envelope carries."
  @spec counters(Relay.Scope.t(), Relay.Id.t()) :: {:ok, map()} | {:error, term()}
  def counters(scope, subscriber_id), do: Relay.Inbox.counters(scope, subscriber_id)

  # IN-37
  # AG-44
  # IN-29
  @doc "At most `limit` AG-UI events after `cursor`, in stream order, each as `%{t, d, cursor}` with the payload text untouched under `d.payload`; the next cursor and whether more wait than one read carries. A cursor that no longer holds is `{:resync_required, reason}`."
  @spec changes(Relay.Scope.t(), Relay.Id.t(), String.t(), pos_integer()) ::
          {:ok, %{changes: [map()], cursor: String.t(), truncated: boolean()}}
          | {:resync_required, String.t()}
          | {:error, term()}
  def changes(%Relay.Scope{} = scope, subscriber_id, cursor, limit) when is_binary(cursor) do
    with {:ok, position} <- Relay.Inbox.decode_cursor(cursor),
         {:ok, mailbox_id} <- mailbox(scope, subscriber_id) do
      read = Relay.Inbox.read(scope, mailbox_id, position.epoch, position.seq, limit)
      page(scope, position, read)
    else
      :error -> {:resync_required, "position_out_of_range"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp page(scope, position, {:ok, page}) do
    changes =
      for %{event_type: @event_type} = record <- page.records,
          {:ok, payload} <- [open(scope, record)] do
        %{
          t: @envelope_type,
          d: %{"id" => Relay.ExternalId.encode("mbr", record.id), "payload" => payload},
          cursor: Relay.Inbox.encode_cursor(%{position | seq: record.seq})
        }
      end

    seq = if page.has_more, do: List.last(page.records).seq, else: page.head_seq
    next = Relay.Inbox.encode_cursor(%{position | epoch: page.epoch, seq: seq})
    {:ok, %{changes: changes, cursor: next, truncated: page.truncated}}
  end

  defp page(_scope, position, {:resync_required, %{epoch: epoch}}) do
    reason = if epoch == position.epoch, do: "position_out_of_range", else: "epoch_changed"
    {:resync_required, reason}
  end

  defp page(_scope, _position, :not_found), do: {:error, :mailbox_not_found}
  defp page(_scope, _position, {:error, reason}), do: {:error, reason}

  defp open(scope, %{payload_ct: ct, payload_tenant_key_id: <<_::128>> = key_id})
       when is_binary(ct) do
    case Relay.Tenancy.decrypt_field(field(scope, key_id), ct) do
      {:ok, plain} -> {:ok, Relay.Redacted.expose(plain)}
      {:error, _reason} -> :error
    end
  end

  defp open(_scope, _record), do: :error
end
