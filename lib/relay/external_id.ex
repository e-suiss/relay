defmodule Relay.ExternalId do
  @moduledoc """
  External identifiers: a type prefix, an underscore and the 16 bytes of a UUIDv7 written as 26 lowercase Crockford base32 characters, for example `ntf_01j9zq3k4m5n6p7q8r9s0t1v2w`. The database stores the `uuid`; the prefix is checked when an identifier is read, so an identifier of one type never resolves as another.
  """

  @alphabet ~c"0123456789abcdefghjkmnpqrstvwxyz"
  @encode @alphabet |> Enum.with_index() |> Map.new(fn {char, value} -> {value, char} end)
  @decode @alphabet |> Enum.with_index() |> Map.new()

  @tables [
    {"ten", "tenants"},
    {"stn", "subtenants"},
    {"sub", "recipients"},
    {"agt", "recipients"},
    {"rcp", "recipients"},
    {"ntf", "notifications"},
    {"dlv", "deliveries"},
    {"att", "delivery_attempts"},
    {"dle", "delivery_events"},
    {"whr", "webhook_receipts"},
    {"oev", "outbox_events"},
    {"aud", "audit_log"},
    {"ckp", "audit_checkpoints"},
    {"dsv", "dataset_versions"},
    {"usg", "usage_records"},
    {"sec", "secret_refs"},
    {"hld", "legal_holds"},
    {"ers", "erasure_log"},
    {"evt", "events"},
    {"cli", "api_clients"},
    {"wfl", "workflows"},
    {"tpl", "templates"},
    {"wp", "waitpoints"},
    {"wpr", "waitpoint_responses"},
    {"dlq", "dead_letters"},
    {"ksw", "kill_switches"},
    {"fan", "fanouts"},
    {"mbx", "mailboxes"},
    {"mbr", "mailbox_records"},
    {"opr", "operators"},
    {"oss", "operator_sessions"},
    {"rla", "role_assignments"},
    {"dlg", "support_delegations"},
    {"tsp", "tenant_suspensions"}
  ]
  @by_prefix Map.new(@tables)

  # API-9
  # T-58
  @doc "Every known prefix."
  @spec prefixes() :: [String.t(), ...]
  def prefixes, do: Enum.map(@tables, &elem(&1, 0))

  @doc "The table an identifier with this prefix resolves to."
  @spec table(String.t()) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  def table(prefix) do
    case Map.fetch(@by_prefix, prefix) do
      {:ok, table} -> {:ok, table}
      :error -> invalid()
    end
  end

  @doc "Formats a UUIDv7 as an external identifier with a known prefix."
  @spec encode(String.t(), Relay.Id.t()) :: String.t()
  def encode(prefix, id) when is_map_key(@by_prefix, prefix) do
    true = Relay.Id.valid?(id)
    prefix <> "_" <> for(<<(value::5 <- <<0::2, id::binary>>)>>, into: "", do: <<@encode[value]>>)
  end

  @doc "Parses an external identifier whose prefix is one of `allowed`; uppercase, unknown or other prefixes are refused."
  @spec decode(term(), [String.t()]) :: {:ok, Relay.Id.t()} | {:error, Relay.Error.t()}
  def decode(text, allowed) when is_binary(text) and is_list(allowed) do
    with [prefix, body] <- String.split(text, "_", parts: 2),
         true <- prefix in allowed and is_map_key(@by_prefix, prefix),
         {:ok, id} <- decode_body(body),
         true <- Relay.Id.valid?(id) do
      {:ok, id}
    else
      _ -> invalid()
    end
  end

  def decode(_text, _allowed), do: invalid()

  defp decode_body(body) when byte_size(body) == 26 do
    values = for <<char <- body>>, do: Map.get(@decode, char)

    if Enum.any?(values, &is_nil/1),
      do: :error,
      else: unpad(for value <- values, into: <<>>, do: <<value::5>>)
  end

  defp decode_body(_body), do: :error

  defp unpad(<<0::2, id::binary-16>>), do: {:ok, id}
  defp unpad(_bits), do: :error

  defp invalid, do: {:error, Relay.Error.new(:invalid_id, "not an identifier of this type")}
end
