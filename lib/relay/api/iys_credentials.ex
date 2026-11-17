defmodule Relay.Api.IysCredentials do
  @moduledoc """
  İYS credentials on the operator surface (PC-29, TN-21, TN-26): the password of the API user a tenant's İYS configuration names. It is taken only as a reference, `${VAR}` or `pkcs11:object=<label>`, resolved once to record its fingerprint and registered as a secret reference of kind `iys_credential` (`Relay.Secrets.register_ref/6`). The answer carries the identifier the configuration names as `credential_ref_id`, the fingerprint, the version and the state; the password and its reference are never returned. Registering a password that is already registered answers its existing reference. The operator pipeline checked the role and the step-up before this runs.
  """

  alias Relay.Api.ChannelManagement, as: Views
  alias Relay.Secrets.Ref

  @type answer :: {:ok, {pos_integer(), map()}} | {:error, Relay.Error.t()}

  # PC-29
  # TN-26 (2)
  # INV-51
  @doc "Registers an İYS password by its secret reference; `201` with its identifier and fingerprint."
  @spec register(Relay.Scope.t(), map(), Relay.Actor.t()) :: answer()
  def register(scope, %{"secret_ref" => text}, actor) do
    digest = Views.digest(scope, "secret_ref.registered", "iys_credential")

    case Relay.Secrets.register_ref(scope, :iys_credential, text, 1, digest, actor) do
      {:ok, ref} -> {:ok, {201, view(ref)}}
      {:error, %Relay.Error{code: code}} -> {:error, refused(code)}
    end
  end

  # INV-51
  @doc "The API view of a registered credential: never the password or its reference."
  @spec view(Ref.t()) :: map()
  def view(%Ref{} = ref) do
    %{
      "object" => "iys_credential",
      "id" => Relay.ExternalId.encode("sec", ref.id),
      "fingerprint" => Ref.fingerprint_hex(ref),
      "version" => ref.ref_version,
      "state" => Atom.to_string(ref.state)
    }
  end

  defp refused(:invalid_secret_ref),
    do: field("invalid_format", "a secret reference is ${VAR} or pkcs11:object=")

  defp refused(:secret_unavailable),
    do: field("not_found", "the secret reference does not resolve")

  defp refused(:secret_retired),
    do: field("conflict", "this secret was retired; register a new one")

  defp refused(_code), do: Views.unavailable()

  defp field(code, detail) do
    Relay.Error.new(:validation_failed, detail, %{
      errors: [%{pointer: "/secret_ref", code: code, detail: detail}]
    })
  end
end
