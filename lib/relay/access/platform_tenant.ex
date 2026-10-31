defmodule Relay.Access.PlatformTenant do
  @moduledoc """
  Suiss products as platform tenants (C-18, E-9, TN-9). A platform tenant is an ordinary tenant with its own sender identities, breakers and reputation keys, like any other tenant, and holds no data isolation privilege; its `platform_product` only sets defaults. For Access (E-10, E-11) a semantic event is a `security` message unless the producer declares another class, and its `dedup_key` derives from the Access event identifier with the CloudEvents derivation (`ce:` ‖ SHA-256 of det-CBOR, S-65), so a repeat of the same event never opens a second notification.
  """

  @products ~w(access work executor one pay)

  @doc "The Suiss products that run as platform tenants."
  @spec products() :: [String.t(), ...]
  def products, do: @products

  # E-10
  # E-11
  # TN-9
  @doc "The message class of a platform tenant's event: the declared class, else `:security` for Access and `nil` otherwise."
  @spec message_class(String.t() | nil, atom() | nil) :: atom() | nil
  def message_class(_product, declared) when is_atom(declared) and not is_nil(declared),
    do: declared

  def message_class("access", nil), do: :security
  def message_class(_product, nil), do: nil

  # E-11
  # API-16
  # API-28
  @doc "The `dedup_key` of an event from its CloudEvents `source` and `id`."
  @spec dedup_key(String.t(), String.t()) :: String.t()
  def dedup_key(source, id) when is_binary(source) and is_binary(id) do
    digest = :crypto.hash(:sha256, Relay.Canonical.encode!(["relay.ce_dedup.v1", source, id]))
    "ce:" <> Base.encode16(digest, case: :lower)
  end
end
