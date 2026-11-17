defmodule Relay.Policy.IysGate.Default do
  @moduledoc """
  The İYS gate of an installation without an İYS integration (PC-27, INV-19): a tenant whose region is Turkey is in scope and has no İYS information, so it is `:not_configured` and its marketing on e-mail, SMS and voice is not sent; every other tenant is `:out_of_scope`.
  """

  @behaviour Relay.Policy.IysGate

  alias Relay.Policy.IysGate
  alias Relay.Policy.IysGate.Store

  # PC-27
  # INV-19
  @impl IysGate
  @doc "`:not_configured` for a tenant of the Turkey region, otherwise `:out_of_scope`."
  @spec status(Relay.Scope.t(), Relay.Id.t() | nil, IysGate.channel(), binary()) ::
          :out_of_scope | :not_configured
  def status(%Relay.Scope{tenant_id: tenant_id}, _brand, _channel, _address_digest) do
    if Store.region(tenant_id) == "tr", do: :not_configured, else: :out_of_scope
  end
end
