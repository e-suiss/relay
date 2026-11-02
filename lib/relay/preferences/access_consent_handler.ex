defmodule Relay.Preferences.AccessConsentHandler do
  @moduledoc """
  The consent copy's handler of the Access `consent.updated` event (E-80, PC-59 (1)): in one tenant environment it finds the subscriber whose `external_id` is the event's pairwise `sub` and records the consent; an older or repeated sequence changes nothing. A `sub` with no subscriber in the environment creates nothing. A consent the copy refuses (an `active` one without its evidence) rejects the event. The evidence is sealed when the event is received (`seal_evidence/3`), so the receipt never holds it in clear; the consent copy keeps that ciphertext. Registered as `config :relay, Relay.Access, consent_handler: Relay.Preferences.AccessConsentHandler`.
  """

  @behaviour Relay.Access.ConsentHandler

  require Logger

  # PC-59 (1)
  # E-80
  @impl Relay.Access.ConsentHandler
  def seal_evidence(scope, sub, evidence) do
    with {:ok, <<_::128>> = id} <- subscriber(scope, sub),
         {:ok, sealed} <- Relay.Preferences.seal_consent_evidence(scope, id, evidence) do
      {:ok,
       %{
         "recipient_id" => Relay.Id.to_string(id),
         "key_id" => Relay.Id.to_string(sealed.evidence_key_id),
         "ct" => Base.encode64(sealed.evidence_ct)
       }}
    else
      {:ok, nil} -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end

  # E-80
  # PC-59 (1)
  # PC-21
  @impl Relay.Access.ConsentHandler
  def handle_consent(scope, consent) do
    case subscriber(scope, consent.sub) do
      {:ok, nil} -> :ok
      {:ok, recipient_id} -> record(scope, prepared(consent, recipient_id))
      {:error, error} -> {:error, error}
    end
  end

  defp subscriber(scope, sub) do
    case Relay.Subscribers.locate(scope, sub) do
      {:ok, id} -> {:ok, id}
      {:error, %Relay.Error{code: :blind_index_key_unavailable}} -> {:ok, nil}
      {:error, %Relay.Error{code: :not_found}} -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end

  defp prepared(consent, recipient_id) do
    consent
    |> Map.merge(%{recipient_id: recipient_id, evidence: nil})
    |> Map.put(:sealed, sealed(Map.get(consent, :sealed_evidence), recipient_id))
  end

  defp sealed(%{"recipient_id" => owner, "key_id" => key_id, "ct" => ct}, recipient_id) do
    with true <- owner == Relay.Id.to_string(recipient_id),
         {:ok, key} <- Relay.Id.parse(key_id),
         {:ok, ciphertext} <- Base.decode64(ct) do
      %{evidence_ct: ciphertext, evidence_key_id: key}
    else
      _other -> nil
    end
  end

  defp sealed(_sealed, _recipient_id), do: nil

  defp record(scope, consent) do
    case Relay.Preferences.record_consent(scope, consent) do
      {:ok, result} when result in [:recorded, :duplicate, :stale] ->
        :ok

      {:ok, refused} ->
        Logger.warning("an Access consent was not recorded", result: refused)
        {:rejected, Atom.to_string(refused)}

      {:error, error} ->
        {:error, error}
    end
  end
end
