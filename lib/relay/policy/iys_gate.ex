defmodule Relay.Policy.IysGate do
  @moduledoc """
  The İYS input of the compliance gate (PC-27, PC-33, INV-19): what the lattice is told about a marketing delivery on an İYS channel (e-mail, SMS, voice) before it decides. The lattice asks once per evaluation, inside its scoped read transaction, and only for those deliveries; informational classes and the other channels are never asked about.

  The answer is one of:

  * `:out_of_scope`: the tenant is outside İYS (its region is not Turkey and it has entered no İYS information); nothing İYS related applies.
  * `:not_configured`: the tenant is in scope and has no İYS information; the delivery is not sent (`iys.not_configured`).
  * `{:cached, state, last_sync_ms}`: the tenant is in scope and configured. `state` is what the local İYS copy holds for the brand, channel and address digest: `:approved`, `:rejected` or `:none`. `last_sync_ms` is the instant of the last successful synchronisation of the copy as Unix milliseconds, `nil` when it never synchronised. The lattice stops the delivery when the copy is older than the stop limit (`x-relay-limits` `iys.stale_stop`).

  The implementation is configured as `config :relay, Relay.Policy.IysGate, impl: …`. Without one, `Relay.Policy.IysGate.Default` answers from the tenant's region alone.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: [Default]

  @type state :: :approved | :rejected | :none
  @type status :: :out_of_scope | :not_configured | {:cached, state(), integer() | nil}
  @type channel :: :email | :sms | :voice

  @callback status(Relay.Scope.t(), Relay.Id.t() | nil, channel(), binary()) :: status()

  # PC-27
  @doc "Returns the configured implementation, `Relay.Policy.IysGate.Default` unless configured otherwise."
  @spec impl() :: module()
  def impl do
    :relay
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:impl, Relay.Policy.IysGate.Default)
  end

  # PC-27
  # PC-33
  @doc "Asks `impl` for the İYS status of a marketing delivery of `scope` to the address with `address_digest` (its blind index) on `channel` for `brand`, the sub-tenant, or `nil` for the tenant itself."
  @spec status(Relay.Scope.t(), Relay.Id.t() | nil, channel(), binary(), module()) :: status()
  def status(scope, brand, channel, address_digest, impl \\ impl()),
    do: impl.status(scope, brand, channel, address_digest)

  # PC-33
  @doc "The age of the local İYS copy, in milliseconds, at which sending stops."
  @spec stale_stop_ms() :: pos_integer()
  def stale_stop_ms, do: Relay.Limits.seconds!(["iys", "stale_stop"]) * 1000

  # PC-33
  @doc "The age of the local İYS copy, in milliseconds, at which a warning is raised."
  @spec stale_warning_ms() :: pos_integer()
  def stale_warning_ms, do: Relay.Limits.seconds!(["iys", "stale_warning"]) * 1000
end
