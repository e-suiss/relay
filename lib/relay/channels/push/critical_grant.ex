defmodule Relay.Channels.Push.CriticalGrant do
  @moduledoc """
  Port to the Access decision API (AuthZEN) for the recipient's explicit Grant of critical interruption to a sender (CH-66, Access E48). Only the recipient grants it; a sender can neither grant nor widen it, and Relay never decides it: the question is asked at send time and every answer comes from Access. An answer that is not an explicit permit, an error or an exception is a denial (fail-closed).
  """

  @typedoc "The question: may `sender_ref` interrupt `recipient_ref` at the critical level in this tenant, for this template."
  @type query :: %{
          tenant_id: Relay.Id.t(),
          recipient_ref: String.t(),
          sender_ref: String.t(),
          template_ref: String.t() | nil
        }

  @typedoc "The decision: `:unavailable` when Access could not answer."
  @type decision :: :permit | :deny | :unavailable

  @doc "Asks Access whether the Grant exists."
  @callback evaluate(query()) :: {:ok, :permit | :deny} | {:error, Relay.Error.t()}

  # CH-66
  @doc "Asks `module` and folds every answer other than an explicit permit into `:deny` or `:unavailable`."
  @spec decide(module(), query()) :: decision()
  def decide(module, query) when is_atom(module) and is_map(query) do
    case module.evaluate(query) do
      {:ok, :permit} -> :permit
      {:ok, :deny} -> :deny
      _other -> :unavailable
    end
  rescue
    _exception -> :unavailable
  catch
    :exit, _reason -> :unavailable
  end
end
