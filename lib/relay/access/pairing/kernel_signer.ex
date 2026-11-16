defmodule Relay.Access.Pairing.KernelSigner do
  @moduledoc """
  The production `Relay.Access.Pairing.Signer` (E-101). It hands the challenge to the key store (`Relay.Keys.sign_pairing/2`) under the label of the service key; the key store port checks the challenge once more against the public half of that key (`kid`, nonces, at least 60 seconds of validity, PEP name), checks the basis, recomputes the intent digests with the Access kernel crate and has the token sign the Actor Intent Statements, so the private key never leaves it (TN-63). A challenge the key store refuses comes back as `{:error, {:unsignable, code}}` with the code of the failed check; any other key store failure comes back as its `Relay.Error`, and nothing is signed.
  """

  @behaviour Relay.Access.Pairing.Signer

  alias Relay.Access.ServiceKey
  alias Relay.Error

  @max_ms 0xFFFFFFFFFFFFFFFF
  @fields [
    :domain,
    :basis,
    :pep,
    :party,
    :kid,
    :challenge,
    :valid_from_ms,
    :valid_until_ms,
    :instance_create,
    :party_register
  ]

  # E-101
  # TN-63
  @impl Relay.Access.Pairing.Signer
  def sign(%{status: :unpaired} = target, <<_::256>>, now_ms) do
    times = [target.valid_from_ms, target.valid_until_ms, now_ms]

    if Enum.all?(times, &(&1 in 0..@max_ms)) do
      request = target |> Map.take(@fields) |> Map.put(:now_ms, now_ms)
      signed(Relay.Keys.sign_pairing(ServiceKey.label(), request), target)
    else
      {:error, {:unsignable, "pairing-validity"}}
    end
  end

  defp signed({:ok, [ais]}, %{party_register: nil}), do: {:ok, %{ais: ais, register_ais: nil}}

  defp signed({:ok, [ais, register_ais]}, %{party_register: %{}}),
    do: {:ok, %{ais: ais, register_ais: register_ais}}

  defp signed({:ok, _statements}, _target), do: {:error, {:unsignable, "pairing-encoding"}}

  defp signed({:error, %Error{code: :key_refused, details: %{reason: code}}}, _target),
    do: {:error, {:unsignable, code}}

  defp signed({:error, %Error{} = error}, _target), do: {:error, error}
end
