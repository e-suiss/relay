defmodule Relay.Actor do
  @moduledoc """
  Who performs an audited action and on whose behalf. Identities are Access identities; Relay never mints them.
  """

  @enforce_keys [:kind, :ref, :on_behalf_of_ref]
  defstruct [:kind, :ref, :on_behalf_of_ref, access_record_ref: nil]

  @type kind :: :operator | :installation_operator | :api_client | :access | :system

  @type t :: %__MODULE__{
          kind: kind(),
          ref: String.t(),
          on_behalf_of_ref: String.t(),
          access_record_ref: String.t() | nil
        }

  @kinds [:operator, :installation_operator, :api_client, :access, :system]

  # TN-48
  # TN-50
  @doc "Builds an actor; references are Access identities of at most 256 characters."
  @spec new(kind(), String.t(), String.t(), String.t() | nil) ::
          {:ok, t()} | {:error, Relay.Error.t()}
  def new(kind, ref, on_behalf_of_ref, access_record_ref \\ nil)

  def new(kind, ref, on_behalf_of_ref, access_record_ref)
      when kind in @kinds and is_binary(ref) and is_binary(on_behalf_of_ref) and
             (is_nil(access_record_ref) or is_binary(access_record_ref)) do
    if ref != "" and on_behalf_of_ref != "" and String.length(ref) <= 256 do
      {:ok,
       %__MODULE__{
         kind: kind,
         ref: ref,
         on_behalf_of_ref: on_behalf_of_ref,
         access_record_ref: access_record_ref
       }}
    else
      invalid()
    end
  end

  def new(_kind, _ref, _on_behalf_of_ref, _access_record_ref), do: invalid()

  @doc "Returns the four positional SQL parameters of an actor, in the order of the write functions."
  @spec params(t()) :: [String.t() | nil, ...]
  def params(%__MODULE__{} = actor),
    do: [Atom.to_string(actor.kind), actor.ref, actor.on_behalf_of_ref, actor.access_record_ref]

  defp invalid, do: {:error, Relay.Error.new(:invalid_actor, "not a valid actor")}
end
