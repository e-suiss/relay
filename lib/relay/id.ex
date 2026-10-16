defmodule Relay.Id do
  @moduledoc """
  UUIDv7 identifiers in the RFC 9562 layout: a 48-bit Unix millisecond timestamp, version 7, 12 random bits, the RFC variant and 62 random bits. Time comes from `Relay.Clock` and randomness from `Relay.Random`. Records sort by `created_at`, not by identifier.
  """

  @type t :: <<_::128>>

  @type kind ::
          :tenant
          | :subtenant
          | :subscriber
          | :agent
          | :recipient
          | :notification
          | :delivery
          | :attempt
          | :delivery_event
          | :webhook_receipt
          | :outbox_event
          | :audit_record
          | :audit_checkpoint
          | :dataset_version
          | :usage_record
          | :secret_ref
          | :legal_hold
          | :erasure_record
          | :event
          | :workflow
          | :template
          | :waitpoint

  @max_ms Integer.pow(2, 48) - 1

  @prefixes [
    tenant: "ten",
    subtenant: "stn",
    subscriber: "sub",
    agent: "agt",
    recipient: "rcp",
    notification: "ntf",
    delivery: "dlv",
    attempt: "att",
    delivery_event: "dle",
    webhook_receipt: "whr",
    outbox_event: "oev",
    audit_record: "aud",
    audit_checkpoint: "ckp",
    dataset_version: "dsv",
    usage_record: "usg",
    secret_ref: "sec",
    legal_hold: "hld",
    erasure_record: "ers",
    event: "evt",
    workflow: "wfl",
    template: "tpl",
    waitpoint: "wp"
  ]

  @kinds Keyword.keys(@prefixes)
  @by_prefix Map.new(@prefixes, fn {kind, prefix} -> {prefix, kind} end)
  @alphabet "0123456789abcdefghjkmnpqrstvwxyz"
  @encode @alphabet |> String.to_charlist() |> List.to_tuple()
  @decode @alphabet |> String.to_charlist() |> Enum.with_index() |> Map.new()

  # OP-1
  # T-60
  # T-57
  @doc "Generates a UUIDv7 from the clock and randomness ports."
  @spec generate() :: t()
  def generate do
    build(DateTime.to_unix(Relay.Clock.utc_now(), :millisecond), Relay.Random.bytes(10))
  end

  @doc "Builds a UUIDv7 from a Unix millisecond timestamp and 10 random bytes, of which 74 bits are used."
  @spec build(non_neg_integer(), <<_::80>>) :: t()
  def build(unix_ms, <<rand_a::12, rand_b::62, _unused::6>>)
      when is_integer(unix_ms) and unix_ms >= 0 and unix_ms <= @max_ms do
    <<unix_ms::48, 7::4, rand_a::12, 2::2, rand_b::62>>
  end

  @doc "Returns true for a 16-byte value with UUID version 7 and the RFC 9562 variant."
  @spec valid?(term()) :: boolean()
  def valid?(<<_ms::48, 7::4, _rand_a::12, 2::2, _rand_b::62>>), do: true
  def valid?(_other), do: false

  @doc "Returns the Unix millisecond timestamp of a UUIDv7."
  @spec timestamp_ms(t()) :: non_neg_integer()
  def timestamp_ms(<<unix_ms::48, 7::4, _rand_a::12, 2::2, _rand_b::62>>), do: unix_ms

  @doc "Formats a UUIDv7 in the RFC 9562 hexadecimal text form, lowercase."
  @spec to_string(t()) :: String.t()
  def to_string(<<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>> = id) do
    true = valid?(id)
    Enum.map_join([a, b, c, d, e], "-", &Base.encode16(&1, case: :lower))
  end

  @doc "Parses the RFC 9562 hexadecimal text form of a UUIDv7; letter case is ignored."
  @spec parse(term()) :: {:ok, t()} | {:error, Relay.Error.t()}
  def parse(<<a::binary-8, ?-, b::binary-4, ?-, c::binary-4, ?-, d::binary-4, ?-, e::binary-12>>) do
    with {:ok, id} <- Base.decode16(a <> b <> c <> d <> e, case: :mixed),
         true <- valid?(id) do
      {:ok, id}
    else
      _ -> invalid()
    end
  end

  def parse(_other), do: invalid()

  defp invalid, do: {:error, Relay.Error.new(:invalid_id, "not a UUIDv7")}

  # API-9
  # API-72
  # T-58 (6)
  @doc "Returns the external identifier kinds with their prefixes."
  @spec prefixes() :: [{kind(), String.t()}, ...]
  def prefixes, do: @prefixes

  @doc "Returns the prefix of an external identifier kind."
  @spec prefix(kind()) :: String.t()
  def prefix(kind) when kind in @kinds, do: Keyword.fetch!(@prefixes, kind)

  @doc "Encodes a UUIDv7 as an external identifier: the kind's prefix, `_` and 26 lowercase Crockford base32 characters."
  @spec encode(kind(), t()) :: String.t()
  def encode(kind, <<_::128>> = id) when kind in @kinds do
    true = valid?(id)

    prefix(kind) <>
      "_" <> for(<<(c::5 <- <<0::2, id::binary>>)>>, into: "", do: <<elem(@encode, c)>>)
  end

  @doc """
  Decodes an external identifier of one of the accepted kinds. The prefix must name an accepted kind and the body must be the canonical lowercase form of a UUIDv7; anything else is refused.
  """
  @spec decode(term(), kind() | [kind(), ...]) :: {:ok, t()} | {:error, Relay.Error.t()}
  def decode(text, kinds) do
    with {:ok, _kind, id} <- decode_kind(text, kinds), do: {:ok, id}
  end

  @doc "Decodes an external identifier and also returns the kind its prefix names."
  @spec decode_kind(term(), kind() | [kind(), ...]) ::
          {:ok, kind(), t()} | {:error, Relay.Error.t()}
  def decode_kind(text, kind) when is_atom(kind), do: decode_kind(text, [kind])

  def decode_kind(text, [_ | _] = kinds) when is_binary(text) do
    with [prefix, body] <- :binary.split(text, "_"),
         {:ok, kind} <- Map.fetch(@by_prefix, prefix),
         true <- kind in kinds,
         {:ok, id} <- decode_body(body) do
      {:ok, kind, id}
    else
      _ -> invalid_external()
    end
  end

  def decode_kind(_text, _kinds), do: invalid_external()

  defp decode_body(<<body::binary-26>>) do
    bits =
      for <<char <- body>>, into: <<>> do
        case Map.fetch(@decode, char) do
          {:ok, value} -> <<value::5>>
          :error -> throw(:invalid)
        end
      end

    case bits do
      <<0::2, id::binary-16>> -> if valid?(id), do: {:ok, id}, else: :error
      _ -> :error
    end
  catch
    :invalid -> :error
  end

  defp decode_body(_body), do: :error

  defp invalid_external,
    do: {:error, Relay.Error.new(:invalid_id, "not an external identifier of the expected kind")}
end
