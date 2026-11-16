defmodule Relay.Api.WebhookCredentials do
  @moduledoc """
  Webhook destination credentials on the operator surface (WH-19, TN-21, TN-26): an OAuth 2.0 client secret, the private key of a mutual TLS certificate, a broker password, a cloud access key or a service account key. A secret is taken only as a reference, `${VAR}` or `pkcs11:object=<label>`, resolved once to record its fingerprint and registered as a secret reference of kind `webhook_destination` (`Relay.Secrets.register_ref/6`). The same operation registers the `v1` secret of a completion source (WH-68) when the body says `kind: source`: a reference of kind `webhook_signing`, which no destination accepts. The answer carries the identifier a destination names as `credential_ref_id`, the fingerprint, the version and the state; the secret and its reference are never returned. Registering a secret that is already registered answers its existing reference. The operator pipeline checked the role and the step-up before this runs.
  """

  alias Relay.Api.ChannelManagement, as: Views
  alias Relay.Secrets.Ref

  @type answer :: {:ok, {pos_integer(), map()}} | {:error, Relay.Error.t()}

  @kinds %{"destination" => :webhook_destination, "source" => :webhook_signing}
  @names Map.new(@kinds, fn {name, kind} -> {kind, name} end)

  # WH-19
  # WH-68
  # TN-26 (2)
  # INV-51
  @doc "Registers a webhook credential by its secret reference; `201` with its identifier and fingerprint. `kind` in the body is `destination` (the default), the credential of a webhook destination, or `source`, the `whsec_` secret a completion source signs with."
  @spec register(Relay.Scope.t(), map(), Relay.Actor.t()) :: answer()
  def register(scope, %{"secret_ref" => text} = body, actor) do
    kind = Map.fetch!(@kinds, Map.get(body, "kind", "destination"))
    digest = Views.digest(scope, "secret_ref.registered", Atom.to_string(kind))

    case Relay.Secrets.register_ref(scope, kind, text, 1, digest, actor) do
      {:ok, ref} -> {:ok, {201, view(ref)}}
      {:error, %Relay.Error{code: code}} -> {:error, refused(code)}
    end
  end

  # INV-51
  @doc "The API view of a registered credential: never the secret or its reference."
  @spec view(Ref.t()) :: map()
  def view(%Ref{} = ref) do
    %{
      "object" => "webhook_credential",
      "id" => Relay.ExternalId.encode("sec", ref.id),
      "fingerprint" => Ref.fingerprint_hex(ref),
      "version" => ref.ref_version,
      "state" => Atom.to_string(ref.state),
      "kind" => Map.fetch!(@names, ref.kind)
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
