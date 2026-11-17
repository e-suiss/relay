defmodule Relay.Preferences.AccessConsentHandler do
  @moduledoc """
  The consent copy's handler of the Access `consent.updated` event (E-80, PC-59 (1)): in one tenant environment it finds the subscriber whose `external_id` is the event's pairwise `sub` and records the consent; an older or repeated sequence changes nothing. A `sub` with no subscriber in the environment creates nothing. A consent the copy refuses (an `active` one without its evidence) rejects the event. The evidence is sealed when the event is received (`seal_evidence/3`), so the receipt never holds it in clear; the consent copy keeps that ciphertext. Registered as `config :relay, Relay.Access, consent_handler: Relay.Preferences.AccessConsentHandler`.

  A consent that belongs in a national consent registry (`Relay.Preferences.ConsentSink`) is written to the registry by Relay (E-21, PC-28): an `active` one is recorded as `pending_iys`, because it is valid only once the registry holds it (PC-30, PC-21), and it and a `revoked` one are handed to the sink after they are recorded. A repeated event hands its consent over again, which the sink takes once; when the sink fails the event comes again.
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

  # E-21
  # PC-30
  defp record(scope, consent) do
    sink = :relay |> Application.get_env(Relay.Preferences, []) |> Keyword.get(:consent_sink)
    registry? = sink != nil and sink.registry?(scope, consent.channel)
    consent = pending(consent, registry?)

    case Relay.Preferences.record_consent_entry(scope, consent) do
      {:ok, {result, id}} when result in [:recorded, :duplicate] ->
        handed(sink, registry?, scope, consent, id)

      {:ok, {:stale, _id}} ->
        :ok

      {:ok, {refused, _id}} ->
        Logger.warning("an Access consent was not recorded", result: refused)
        {:rejected, Atom.to_string(refused)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp pending(%{status: "active"} = consent, true), do: %{consent | status: "pending_iys"}
  defp pending(consent, _registry?), do: consent

  defp handed(sink, true, scope, %{status: status} = consent, <<_::128>> = id)
       when status in ["pending_iys", "revoked"] do
    recorded =
      consent
      |> Map.take([:recipient_id, :brand_subtenant_id, :channel, :status, :recipient_type])
      |> Map.merge(%{consent_id: id, source: consent.source, occurred_at: consent.occurred_at})

    sink.recorded(scope, recorded)
  end

  defp handed(_sink, _registry?, _scope, _consent, _id), do: :ok
end
