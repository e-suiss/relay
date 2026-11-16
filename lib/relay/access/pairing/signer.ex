defmodule Relay.Access.Pairing.Signer do
  @moduledoc """
  The port that signs a pairing challenge (E-101): given an `unpaired` target whose kernel-free checks held (`Relay.Access.Pairing.Target.check/3`), the 32-byte public service key and the Unix millisecond of signing, it checks that the basis is the Genesis bootstrap Grant of the domain, recomputes the `instance_create` intent digest (and the `party_register` one when the target names it) with the Access kernel and compares them with Access's, builds the Actor Intent Statements (`mode` commit, `capacity` own, the target's domain, nonce, basis and PEP, `iat` the given millisecond) and signs each with the service key as a tagged `COSE_Sign1` (`alg` -19, `kid` the key's thumbprint, content type `application/access-ais+cbor`). A digest Relay does not recompute itself is never signed.

  `{:error, {:unsignable, code}}` names the check that failed: one of the checks of `Relay.Access.Pairing.Target.check/3` made again where the key signs (`pairing-kid`, `pairing-nonce`, `pairing-register-nonce`, `pairing-validity`, `pairing-pep`), `pairing-basis`, `pairing-instance-intent`, `pairing-register-intent`, `pairing-encoding`, or `pairing-signature` for a signature that does not verify under the service key. A `Relay.Error` is a failure of the key store itself.
  """

  alias Relay.Access.Pairing.Target

  @type signed :: %{ais: binary(), register_ais: binary() | nil}
  @type error :: {:unsignable, Target.unsignable()} | Relay.Error.t()

  @callback sign(Target.unpaired(), <<_::256>>, integer()) :: {:ok, signed()} | {:error, error()}
end
