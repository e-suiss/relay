defmodule Relay.Audit.Record do
  @moduledoc """
  Commitments over audit records, both deterministic CBOR (`Relay.Canonical`).

  The record digest (`audit_log.record_digest`) is `SHA-256(det-CBOR(record))` over the fields the caller knows before the database assigns the row's time: scope, action, actor, on-behalf-of, Access record, target, reason and the digest of the plaintext details.

  The Merkle leaf is `SHA-256(0x00 ‖ det-CBOR(envelope))`, where the envelope binds the leaf's address in the log to the record: `origin`, `pos` (leaf index), `tenant_id`, `environment`, `audit_id`, `recorded_at` (microseconds since the Unix epoch, UTC) and `record_digest`. The `0x00` prefix is the RFC 6962 leaf domain separation that Access uses (`0x01` is reserved for interior nodes and field commitments).
  """

  alias Relay.Audit.Merkle

  @type t :: %{
          required(:tenant_id) => Relay.Id.t(),
          required(:environment) => String.t(),
          required(:action) => String.t(),
          required(:actor_kind) => String.t(),
          required(:actor_ref) => String.t(),
          required(:on_behalf_of_ref) => String.t(),
          optional(:access_record_ref) => String.t() | nil,
          optional(:target_type) => String.t() | nil,
          optional(:target_id) => String.t() | nil,
          optional(:reason) => String.t() | nil,
          optional(:details) => binary() | nil
        }

  @type leaf :: %{
          tenant_id: Relay.Id.t(),
          environment: String.t(),
          audit_id: Relay.Id.t(),
          created_at: DateTime.t(),
          record_digest: <<_::256>>
        }

  @version 1

  # TN-46
  # TN-50
  @doc "Computes the record digest passed to the audit-writing functions."
  @spec digest(t()) :: <<_::256>>
  def digest(%{tenant_id: <<_::128>> = tenant_id, environment: environment} = record)
      when environment in ["live", "test"] do
    details =
      case Map.get(record, :details) do
        nil -> nil
        details when is_binary(details) -> {:bytes, :crypto.hash(:sha256, details)}
      end

    :crypto.hash(
      :sha256,
      Relay.Canonical.encode!(%{
        "v" => @version,
        "tenant_id" => {:bytes, tenant_id},
        "environment" => environment,
        "action" => text!(record.action),
        "actor_kind" => text!(record.actor_kind),
        "actor_ref" => text!(record.actor_ref),
        "on_behalf_of_ref" => text!(record.on_behalf_of_ref),
        "access_record_ref" => optional_text(record, :access_record_ref),
        "target_type" => optional_text(record, :target_type),
        "target_id" => optional_text(record, :target_id),
        "reason" => optional_text(record, :reason),
        "details_digest" => details
      })
    )
  end

  # OP-63
  @doc "Encodes the leaf envelope of a record at `pos` in the log `origin`."
  @spec envelope(String.t(), non_neg_integer(), leaf()) :: binary()
  def envelope(origin, pos, %{
        tenant_id: <<_::128>> = tenant_id,
        environment: environment,
        audit_id: <<_::128>> = audit_id,
        created_at: %DateTime{} = created_at,
        record_digest: <<_::256>> = record_digest
      })
      when is_binary(origin) and is_integer(pos) and pos >= 0 do
    Relay.Canonical.encode!(%{
      "origin" => origin,
      "pos" => pos,
      "tenant_id" => {:bytes, tenant_id},
      "environment" => environment,
      "audit_id" => {:bytes, audit_id},
      "recorded_at" => DateTime.to_unix(created_at, :microsecond),
      "record_digest" => {:bytes, record_digest}
    })
  end

  @doc "Computes the Merkle leaf hash of a record at `pos` in the log `origin`."
  @spec leaf_hash(String.t(), non_neg_integer(), leaf()) :: Merkle.hash()
  def leaf_hash(origin, pos, leaf), do: Merkle.leaf_hash(envelope(origin, pos, leaf))

  defp text!(value) when is_binary(value) and value != "", do: value

  defp optional_text(record, key) do
    case Map.get(record, key) do
      nil -> nil
      value when is_binary(value) -> value
    end
  end
end
