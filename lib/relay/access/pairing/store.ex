defmodule Relay.Access.Pairing.Store do
  @moduledoc """
  Data access of the pairing (E-101): the active Access tenants, Relay's pairing state with each of their realms (`relay.access_pairing_realms`: `unpaired`, `paired`, `refused` or `retired`, the `kid`, governing domain, service Party and Instance it is paired or challenged under, Access's refusal code and the failed runs in a row) and Relay's Access event stream (`relay.access_event_stream`, one row). Rows are written only through `relay_ops` functions; nothing is ever deleted, a realm that leaves the tenant snapshot is `retired` (INV-47).
  """

  alias Relay.Repo

  @realms "SELECT realm, slug, state, kid, failed_runs FROM relay.access_pairing_realms WHERE access_tenant_id = $1 ORDER BY realm"
  @stalled "SELECT count(*) FROM relay.access_pairing_realms WHERE state IN ('unpaired', 'refused') AND failed_runs >= $1"
  @stream "SELECT stream, status, recreated FROM relay.access_event_stream WHERE singleton"
  @states %{
    "unpaired" => :unpaired,
    "paired" => :paired,
    "refused" => :refused,
    "retired" => :retired
  }
  @stream_statuses %{
    "enabled" => :enabled,
    "paused" => :paused,
    "disabled" => :disabled,
    "unreachable" => :unreachable
  }

  @type state :: :unpaired | :paired | :refused | :retired
  @type realm :: %{
          realm: String.t(),
          slug: String.t(),
          state: state(),
          kid: binary() | nil,
          failed_runs: non_neg_integer()
        }
  @type challenged :: %{kid: binary(), domain: binary(), party: binary()}
  @type instance :: %{kid: binary(), domain: binary() | nil, party: binary(), instance: binary()}
  @type change ::
          {:unpaired, challenged()} | {:paired, instance()} | {:refused, String.t()} | :failed
  @type stream :: %{stream: String.t() | nil, status: atom() | nil, recreated: non_neg_integer()}

  # E-101
  @doc "One page of the active Access tenants after `after` (`nil` for the first), in byte order."
  @spec tenants(String.t() | nil, pos_integer()) :: [String.t()]
  def tenants(after_id, limit) do
    params = [after_id, limit]
    rows = Repo.call_unscoped!(:access_pairing, "relay_ops.access_pairing_tenants", params)
    Enum.map(rows, & &1["access_tenant_id"])
  end

  # E-101
  # INV-47
  @doc "Records the live realms of a tenant snapshot (`{realm, slug}`): a new one is `unpaired`, a retired one is `unpaired` again, and every other realm of the tenant is retired; returns how many were retired."
  @spec seen(String.t(), [{String.t(), String.t()}]) :: non_neg_integer()
  def seen(access_tenant_id, realms) do
    ids = Enum.map(realms, &uuid(elem(&1, 0)))
    slugs = Enum.map(realms, &elem(&1, 1))
    params = [access_tenant_id, ids, slugs]
    [row] = Repo.call_unscoped!(:access_pairing, "relay_ops.access_pairing_seen", params)
    row["access_pairing_seen"]
  end

  # E-101
  @doc "Applies one change to a stored realm; `{:ok, runs}` gives its failed runs in a row after the change."
  @spec change(String.t(), String.t(), change()) :: {:ok, non_neg_integer()} | :not_found
  def change(access_tenant_id, realm, change) do
    params = [access_tenant_id, uuid(realm) | change_params(change)]

    case Repo.call_unscoped!(:access_pairing, "relay_ops.access_pairing_apply", params) do
      [%{"result" => "stored", "runs" => runs}] -> {:ok, runs}
      [%{"result" => result}] -> Repo.code!(result, [:not_found])
    end
  end

  defp change_params({:unpaired, fields}),
    do: ["unpaired", fields.kid, fields.domain, fields.party, nil, nil]

  defp change_params({:paired, fields}),
    do: ["paired", fields.kid, fields.domain, fields.party, fields.instance, nil]

  defp change_params({:refused, code}), do: ["refused", nil, nil, nil, nil, code]
  defp change_params(:failed), do: ["failed", nil, nil, nil, nil, nil]

  # E-101
  @doc "The stored realms of a tenant."
  @spec realms(String.t()) :: [realm()]
  def realms(access_tenant_id) do
    for [realm, slug, state, kid, runs] <- query!(@realms, [access_tenant_id]) do
      %{
        realm: text(realm),
        slug: slug,
        state: Map.fetch!(@states, state),
        kid: kid,
        failed_runs: runs
      }
    end
  end

  # E-101
  @doc "How many realms of the installation are not paired after `runs` or more failed runs in a row."
  @spec stalled(pos_integer()) :: non_neg_integer()
  def stalled(runs) do
    [[count]] = query!(@stalled, [runs])
    count
  end

  # E-101
  @doc "The recorded event stream, `nil` before the first record."
  @spec stream() :: stream() | nil
  def stream do
    case query!(@stream, []) do
      [[stream, status, recreated]] ->
        %{stream: stream && text(stream), status: status(status), recreated: recreated}

      [] ->
        nil
    end
  end

  # E-101
  @doc "Records the stream Relay found or opened (`nil` when there is none) and its status; `recreated?` counts one more reopening. Returns the reopenings so far."
  @spec record_stream(String.t() | nil, atom() | nil, boolean()) :: non_neg_integer()
  def record_stream(stream, status, recreated?) do
    params = [stream && uuid(stream), status && Atom.to_string(status), recreated?]
    [row] = Repo.call_unscoped!(:access_pairing, "relay_ops.access_event_stream_record", params)
    row["access_event_stream_record"]
  end

  defp status(nil), do: nil
  defp status(status), do: Map.fetch!(@stream_statuses, status)

  defp query!(sql, params) do
    case Repo.unscoped_query(:access_pairing, sql, params) do
      {:ok, %{rows: rows}} -> rows
      {:error, error} -> raise error
    end
  end

  defp uuid(text), do: text |> String.replace("-", "") |> Base.decode16!(case: :lower)

  defp text(<<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>>),
    do: Enum.map_join([a, b, c, d, e], "-", &Base.encode16(&1, case: :lower))
end
