defmodule Relay.Access.Pairing.KernelSigner do
  @moduledoc """
  The production `Relay.Access.Pairing.Signer` (E-101). The intent digests and the `COSE_Sign1` signatures are computed in the key store port with the Access kernel crate, which this build does not carry yet, so every challenge is answered `{:error, :kernel_unavailable}`: nothing is signed and every unpaired realm stays unpaired.
  """

  @behaviour Relay.Access.Pairing.Signer

  # E-101
  @impl Relay.Access.Pairing.Signer
  def sign(_target, _service_key, _now_ms), do: {:error, :kernel_unavailable}
end
