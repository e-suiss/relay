defmodule Relay.Iys.Permissions do
  @moduledoc """
  The local copy of what İYS holds: the permission cache (PC-32, PC-33, PC-21, PC-24).

  A cached permission is the status İYS recorded last for a brand, an İYS type (`MESAJ`, `ARAMA`, `EPOSTA`), a legal recipient type and an address. The address is kept only as its blind index, the one subscriber addresses and suppressions use, under the current key and, while a key rotation runs, under the key before it, so a lookup with either matches. A new movement supersedes the row it replaces; nothing is deleted.

  The cache is written from three places: the pull of consent movements (`Relay.Iys.Sync`), the read-back that confirms an upload of the write path (`confirmed/3`), and a single verification against İYS (`verify/2`, `check/5`). Only the single verification asks İYS; `status/4`, what the lattice reads for a marketing delivery, is one statement on the cache and never a request (PC-32).

  `status/4` answers `:out_of_scope` for a tenant outside İYS, `:not_configured` for a tenant in scope without a configuration or without a brand for the sub-tenant, and otherwise `{:cached, state, last_sync_ms}`: `:rejected` when any recipient type of the address holds a rejection, `:approved` when one holds an approval, `:none` when İYS holds nothing. `last_sync_ms` is the last pull that reached the end of İYS's movements. An approval that was last verified before a gap in the pulls longer than İYS's window of movements answers no synchronisation at all, so it is read as a stale copy until it was verified again (INV-43).
  """

  alias Relay.Iys
  alias Relay.Iys.Calendar
  alias Relay.Iys.Client
  alias Relay.Iys.Consent
  alias Relay.Iys.Store
  alias Relay.Scope

  @types ~w(MESAJ ARAMA EPOSTA)
  @statuses ~w(ONAY RET)
  @source ~r/\A[A-Z][A-Z0-9_]{1,31}\z/

  @type state :: :approved | :rejected | :none
  @type status :: :out_of_scope | :not_configured | {:cached, state(), integer() | nil}

  # PC-27
  # PC-33
  # PC-24
  # INV-19
  # INV-43
  @doc "The İYS status of a marketing delivery on `channel` to the address with `digest` for the brand of `subtenant_id` (`nil` for the tenant), read inside the caller's scoped transaction."
  @spec status(Scope.t(), Relay.Id.t() | nil, String.t(), binary()) :: status()
  def status(%Scope{tenant_id: tenant_id}, subtenant_id, channel, digest)
      when is_binary(digest) do
    case Consent.type(channel) do
      {:ok, type} -> read(Store.gate(tenant_id, subtenant_id, type, digest))
      :out_of_scope -> :out_of_scope
    end
  end

  defp read([]), do: :not_configured

  defp read([%{"config_id" => nil, "region" => region} | _rest]),
    do: if(region in [nil, "tr"], do: :not_configured, else: :out_of_scope)

  defp read([%{"brand_id" => nil} | _rest]), do: :not_configured

  defp read([first | _rest] = rows) do
    synced = milliseconds(first["last_pull_at"])
    floor = first["full_sync_floor_at"]
    held = for %{"consent_status" => status} = row when is_binary(status) <- rows, do: row

    cond do
      Enum.any?(held, &(&1["consent_status"] == "RET")) -> {:cached, :rejected, synced}
      held == [] -> {:cached, :none, synced}
      Enum.any?(held, &verified?(&1["verified_at"], floor)) -> {:cached, :approved, synced}
      true -> {:cached, :approved, nil}
    end
  end

  defp milliseconds(nil), do: nil
  defp milliseconds(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)

  defp verified?(_verified_at, nil), do: true
  defp verified?(verified_at, floor), do: DateTime.compare(verified_at, floor) != :lt

  # PC-32
  @doc "The cache movements of a page of İYS movements, oldest first: each with the blind indexes of its recipient, computed outside any transaction. A movement of a type or status İYS does not document is left out."
  @spec movements(Scope.t(), [map()]) :: {:ok, [map()]} | {:error, term()}
  def movements(%Scope{} = scope, list) when is_list(list) do
    runtime = Iys.runtime()

    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case movement(scope, runtime, item) do
        {:ok, movement} -> {:cont, {:ok, [movement | acc]}}
        :skip -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, movements} -> {:ok, Enum.reverse(movements)}
      error -> error
    end
  end

  defp movement(scope, runtime, %{"recipient" => recipient, "type" => type} = item)
       when is_binary(recipient) and type in @types do
    channel = Consent.channel(type)

    with true <- item["status"] in @statuses,
         {:ok, digests} <- runtime.digests(scope, channel, Consent.recipient(type, recipient)) do
      {:ok, entry(item, digests)}
    else
      false -> :skip
      {:error, reason} -> {:error, reason}
    end
  end

  defp movement(_scope, _runtime, _item), do: :skip

  defp entry(item, [{key_id, digest} | older]) do
    base = %{
      "type" => item["type"],
      "status" => item["status"],
      "recipient_type" => recipient_type(item["recipientType"]),
      "source" => source(item["source"]),
      "consent_at" => Calendar.parse_time(item["consentDate"]),
      "registered_at" => Calendar.parse_time(item["creationDate"]),
      "transaction_ref" => reference(item["transactionId"]),
      "digest" => Base.encode16(digest, case: :lower),
      "digest_key_id" => Relay.Id.to_string(key_id)
    }

    Map.merge(base, alternate(older))
  end

  defp alternate([{key_id, digest} | _rest]) do
    %{
      "digest_alt" => Base.encode16(digest, case: :lower),
      "digest_alt_key_id" => Relay.Id.to_string(key_id)
    }
  end

  defp alternate([]), do: %{"digest_alt" => nil, "digest_alt_key_id" => nil}

  defp recipient_type("TACIR"), do: "TACIR"
  defp recipient_type(_individual), do: "BIREYSEL"

  defp source(source) when is_binary(source),
    do: if(Regex.match?(@source, source), do: source, else: "UNKNOWN")

  defp source(_other), do: "UNKNOWN"

  defp reference(text) when is_binary(text) and text != "", do: String.slice(text, 0, 128)
  defp reference(_other), do: nil

  # PC-30
  # PC-32
  @doc "Writes the movement of an upload İYS confirmed into the cache, inside the transaction that settles the upload; `detail` carries what the read-back answered."
  @spec confirmed(map(), map(), DateTime.t()) :: :ok
  def confirmed(%{"brand_id" => <<_::128>> = brand_id} = upload, detail, %DateTime{} = now) do
    movement = %{
      "type" => upload["consent_type"],
      "status" => upload["consent_status"],
      "recipient_type" => upload["recipient_type"],
      "source" => upload["source"],
      "consent_at" => upload["consent_at"],
      "registered_at" => detail["registered_at"] || upload["registered_at"],
      "transaction_ref" => detail["transaction_ref"] || upload["transaction_ref"],
      "digest" => Base.encode16(upload["address_digest"], case: :lower),
      "digest_key_id" => Relay.Id.to_string(upload["address_digest_key_id"]),
      "digest_alt" => nil,
      "digest_alt_key_id" => nil
    }

    {:applied, _count} = Store.permissions_apply(brand_id, "upload", nil, nil, [movement], now)
    :ok
  end

  def confirmed(_upload, _detail, _now), do: :ok

  # PC-32
  # OP-42
  @doc "Reads one cached permission again from İYS and writes what İYS holds: the same status is verified, another status replaces it (a rejection then waits to be applied in Relay), and nothing held withdraws it. `row` carries the permission's `id`, `consent_type`, `recipient_type` and the `recipient_id` whose address is asked about. `:skip` when the address cannot be read."
  @spec check(Scope.t(), Client.conn(), map(), map(), DateTime.t()) ::
          :ok | :skip | {:error, term()}
  def check(%Scope{} = scope, conn, brand, %{"recipient_id" => <<_::128>> = id} = row, now) do
    type = row["consent_type"]

    case Iys.runtime().recipient_address(scope, id, Consent.channel(type)) do
      {:ok, address} when is_binary(address) ->
        query = %{type: type, recipient_type: row["recipient_type"], address: address}
        asked(scope, conn, brand, query, row["id"], now)

      _unreadable ->
        :skip
    end
  end

  def check(_scope, _conn, _brand, _row, _now), do: :skip

  defp asked(scope, conn, brand, query, permission_id, now) do
    recipient = Consent.recipient(query.type, query.address)
    question = %{recipient: recipient, type: query.type, recipient_type: query.recipient_type}

    case Client.consent_status(conn, brand["brand_code"], question) do
      {:ok, nil} -> withdrawn(scope, permission_id, now)
      {:ok, held} -> held(scope, brand, Map.put(query, :address, recipient), held, now)
      {:error, failure} -> {:error, failure}
    end
  end

  defp withdrawn(_scope, nil, _now), do: :ok

  defp withdrawn(scope, permission_id, now) do
    work = fn _status -> Store.permission_mark(permission_id, "withdrawn", now) end
    with {:ok, _marked} <- Store.in_scope(scope, work), do: :ok
  end

  defp held(scope, brand, query, held, now) do
    item = %{
      "recipient" => query.address,
      "type" => query.type,
      "status" => held.status,
      "recipientType" => query.recipient_type,
      "source" => held.source,
      "transactionId" => held.transaction_id
    }

    times = %{"consent_at" => held.consent_at, "registered_at" => held.registered_at}

    case movements(scope, [item]) do
      {:ok, [movement]} -> written(scope, brand, Map.merge(movement, times), now)
      {:ok, []} -> :skip
      {:error, reason} -> {:error, reason}
    end
  end

  defp written(scope, brand, movement, now) do
    work = fn _status ->
      Store.permissions_apply(brand["id"], "verify", nil, nil, [movement], now)
    end

    with {:ok, _applied} <- Store.in_scope(scope, work), do: :ok
  end

  # PC-32
  @doc """
  Verifies one address against İYS, the only place a consent status is asked live, and writes the answer into the cache. `query` carries `:channel`, `:address` and optionally `:brand_subtenant_id` and `:recipient_type` (`individual` unless `merchant`). Runs outside any transaction. Answers what İYS holds, or `:not_configured` and `:out_of_scope` as the gate does.
  """
  @spec verify(Scope.t(), map()) ::
          {:ok, state() | :not_configured | :out_of_scope} | {:error, term()}
  def verify(%Scope{} = scope, %{channel: channel, address: address} = query)
      when is_binary(address) do
    case Consent.type(channel) do
      {:ok, type} -> verified(scope, type, query)
      :out_of_scope -> {:ok, :out_of_scope}
    end
  end

  defp verified(scope, type, query) do
    subtenant_id = Map.get(query, :brand_subtenant_id)
    read = fn _status -> {Store.config(), Store.sync_states()} end

    with {:ok, {%{} = config, brands}} <- Store.in_scope(scope, read),
         %{} = brand <- Enum.find(brands, &bound?(&1, subtenant_id)),
         {:ok, conn} <- Iys.connection(scope, config) do
      recipient_type = Consent.recipient_type(Map.get(query, :recipient_type))
      asked = %{type: type, recipient_type: recipient_type, address: query.address}
      live(scope, conn, brand, asked)
    else
      {:ok, {nil, _brands}} -> {:ok, :not_configured}
      nil -> {:ok, :not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bound?(brand, subtenant_id),
    do: brand["sender_identity_id"] == nil and brand["subtenant_id"] == subtenant_id

  defp live(scope, conn, brand, query) do
    now = Relay.Clock.utc_now()
    query = %{query | address: Consent.recipient(query.type, query.address)}
    question = %{recipient: query.address, type: query.type, recipient_type: query.recipient_type}

    case Client.consent_status(conn, brand["brand_code"], question) do
      {:ok, nil} -> answered(forgotten(scope, brand, query, now), :none)
      {:ok, %{status: "RET"} = held} -> answered(held(scope, brand, query, held, now), :rejected)
      {:ok, held} -> answered(held(scope, brand, query, held, now), :approved)
      {:error, failure} -> {:error, failure}
    end
  end

  defp answered({:error, reason}, _state), do: {:error, reason}
  defp answered(_written, state), do: {:ok, state}

  defp forgotten(scope, brand, query, now) do
    channel = Consent.channel(query.type)

    with {:ok, digests} <- Iys.runtime().digests(scope, channel, query.address) do
      values = Enum.map(digests, fn {_key_id, digest} -> digest end)

      work = fn _status ->
        brand["id"]
        |> Store.current_permissions(query.type, query.recipient_type, values)
        |> Enum.each(&Store.permission_mark(&1["id"], "withdrawn", now))
      end

      with {:ok, _done} <- Store.in_scope(scope, work), do: :ok
    end
  end
end
