defmodule Relay.Migration.Bucket do
  @moduledoc """
  The sticky bucket of a recipient in a staged rollout (OP-53, OP-95): SHA-256 over the 16 bytes of the tenant's UUID, one `0x00` byte and the UTF-8 bytes of the recipient's external identifier; the first 8 bytes of the digest, read as an unsigned big-endian integer, modulo 10000. The digest itself, in lowercase hex, is how a pinned recipient list keeps an external identifier. The vectors under `conformance/vectors/rollout-bucket` fix the rule.
  """

  @buckets Relay.Limits.fetch!(["rollout", "buckets"])

  @type bucket :: 0..9999

  # OP-95
  @doc "The digest of a tenant's external identifier: SHA-256(tenant id bytes ‖ 0x00 ‖ external id)."
  @spec digest(Relay.Id.t(), String.t()) :: <<_::256>>
  def digest(<<_::128>> = tenant_id, external_id) when is_binary(external_id),
    do: :crypto.hash(:sha256, [tenant_id, <<0>>, external_id])

  # OP-53
  # OP-95
  @doc "The bucket of a recipient, from 0 to 9999."
  @spec bucket(Relay.Id.t(), String.t()) :: bucket()
  def bucket(tenant_id, external_id) do
    <<head::unsigned-big-integer-size(64), _rest::binary>> = digest(tenant_id, external_id)
    rem(head, @buckets)
  end

  @doc "The number of buckets."
  @spec buckets() :: pos_integer()
  def buckets, do: @buckets
end
