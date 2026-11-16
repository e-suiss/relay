defmodule Relay.Api.OperationsContacts do
  @moduledoc """
  The tenant's operations contact addresses on the server API (WH-56): the recipients of Relay's operational e-mails about its webhook endpoints, at most `Relay.Webhooks.contacts_max/0`. The list is read and replaced as a whole. An address is personal data: it is sealed under the tenant's data key before the request's transaction and a removed address is erased. The replacement is audited.
  """

  alias Relay.Api.Gate
  alias Relay.Scope

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @address ~r/\A[^@\s]{1,64}@[^@\s]{1,253}\z/

  # WH-56
  @doc "The operations contacts of the scope."
  @spec get(Scope.t()) :: answer()
  def get(%Scope{} = scope) do
    case Relay.Webhooks.contacts(scope) do
      {:ok, %{addresses: addresses, updated_at: updated_at}} ->
        {:ok, {200, [], view(Enum.map(addresses, &Relay.Redacted.expose/1), updated_at)}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # WH-56
  @doc "Checks the addresses of a replacement and seals them, outside any transaction."
  @spec prepare(Scope.t(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def prepare(%Scope{} = scope, %{"emails" => emails}) do
    with :ok <- addresses(emails) do
      case Relay.Webhooks.seal_contacts(scope, emails) do
        {:ok, sealed} -> {:ok, %{emails: emails, sealed: sealed}}
        {:error, _error} -> {:error, unavailable()}
      end
    end
  end

  defp addresses(emails) do
    errors =
      for {email, index} <- Enum.with_index(emails), not Regex.match?(@address, email) do
        pointer = "/emails/#{index}"
        %{pointer: pointer, code: "invalid_format", detail: "not an e-mail address"}
      end

    if errors == [],
      do: :ok,
      else: {:error, Relay.Error.new(:validation_failed, "invalid address", %{errors: errors})}
  end

  # WH-56
  # WH-48
  @doc "Replaces the operations contacts with prepared addresses inside the request's transaction."
  @spec replace(Scope.t(), map(), Relay.Actor.t()) :: answer()
  def replace(%Scope{} = scope, %{emails: emails, sealed: sealed}, actor) do
    digest = Gate.digest(scope, "operations_contacts.replaced", Integer.to_string(length(emails)))

    case Relay.Webhooks.contacts_replace(sealed, digest, actor) do
      :replaced ->
        {:ok, {200, [], view(emails, Relay.Clock.utc_now())}}

      :tenant_inactive ->
        {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}
    end
  end

  defp view(emails, updated_at) do
    %{
      "object" => "operations_contacts",
      "emails" => Enum.sort(emails),
      "updated_at" => updated_at
    }
  end

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
