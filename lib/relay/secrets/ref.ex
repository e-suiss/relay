defmodule Relay.Secrets.Ref do
  @moduledoc """
  A stored secret reference as it is read back: identity, kind, version, state and fingerprint. It never carries the secret or the reference text.
  """

  @enforce_keys [:id, :kind, :ref_version, :fingerprint, :state]
  @derive {Inspect, only: [:id, :kind, :ref_version, :state, :fingerprint]}
  defstruct [:id, :kind, :ref_version, :fingerprint, :state, :created_at, :retired_at]
  use Relay.Hygiene, shown_fields: [:id, :kind, :ref_version, :state, :fingerprint]

  @type t :: %__MODULE__{
          id: Relay.Id.t(),
          kind: Relay.Secrets.kind(),
          ref_version: pos_integer(),
          fingerprint: <<_::256>>,
          state: :active | :retired,
          created_at: DateTime.t() | nil,
          retired_at: DateTime.t() | nil
        }

  # INV-51
  @doc "Returns the fingerprint as lowercase hex, the only form in which a secret is shown."
  @spec fingerprint_hex(t()) :: String.t()
  def fingerprint_hex(%__MODULE__{fingerprint: fingerprint}),
    do: Base.encode16(fingerprint, case: :lower)
end
