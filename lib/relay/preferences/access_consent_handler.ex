defmodule Relay.Preferences.AccessConsentHandler do
  @moduledoc """
  The consent copy's handler of the Access `consent.updated` event (E-80, PC-59 (1)): in one tenant environment it finds the subscriber whose `external_id` is the event's pairwise `sub` and records the consent; an older or repeated sequence changes nothing. A `sub` with no subscriber in the environment creates nothing. A consent the copy refuses (an `active` one without its evidence) rejects the event. Registered as `config :relay, Relay.Access, consent_handler: Relay.Preferences.AccessConsentHandler`.
  """

  @behaviour Relay.Access.ConsentHandler

  require Logger

  # E-80
  # PC-59 (1)
  # PC-21
  @impl Relay.Access.ConsentHandler
  def handle_consent(scope, consent) do
    case Relay.Subscribers.locate(scope, consent.sub) do
      {:ok, nil} -> :ok
      {:ok, recipient_id} -> record(scope, Map.put(consent, :recipient_id, recipient_id))
      {:error, %Relay.Error{code: :blind_index_key_unavailable}} -> :ok
      {:error, %Relay.Error{code: :not_found}} -> :ok
      {:error, error} -> {:error, error}
    end
  end

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
