defmodule Relay.Preferences.ConsentSink do
  @moduledoc """
  The behaviour of the registry writer behind the consent copy (E-21, PC-28, PC-30): the consumer of the Access `consent.updated` event asks it whether a consent of a channel belongs in a national consent registry, records such an approval as `pending_iys` instead of `active`, and hands every recorded approval and refusal to it, so that Relay, and never Access, writes the registry. It is named in `config :relay, Relay.Preferences, consent_sink: module`; without one no consent belongs in a registry.
  """

  @doc "Whether a consent of `channel` in the scope belongs in the registry."
  @callback registry?(scope :: Relay.Scope.t(), channel :: String.t()) :: boolean()

  @doc "Takes a recorded consent of the registry's scope: `:consent_id`, `:recipient_id`, `:brand_subtenant_id`, `:channel`, `:status` (`pending_iys` or `revoked`), `:recipient_type`, `:source` and `:occurred_at`. Called outside any transaction, at least once for a consent; an error makes the event come again."
  @callback recorded(scope :: Relay.Scope.t(), consent :: map()) :: :ok | {:error, term()}
end
