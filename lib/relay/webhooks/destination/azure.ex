defmodule Relay.Webhooks.Destination.Azure do
  @moduledoc """
  What the Azure destinations share (WH-17): the authorization of an endpoint that is reached with a managed identity.

  A managed identity belongs to the installation, not to the endpoint, and its token comes from the platform the installation runs on, an address the egress boundary refuses for every delivery (WH-54). It is therefore never fetched here: the caller passes `:managed_identity`, a function that is given the client identifier of the endpoint's configuration and the resource the token is for and returns the token as a wrapped value, or a failure. Without that function the identity is not available and the attempt is retried later. The token appears in no failure and in no receipt (WH-19).
  """

  alias Relay.Redacted
  alias Relay.Webhooks.Destination
  alias Relay.Webhooks.Destination.Cloud

  @type identity ::
          (client_id :: String.t(), resource :: String.t() ->
             {:ok, Redacted.t()} | {:error, Destination.failure()})

  # WH-17
  @doc "The `authorization` header of a managed identity for `resource`, from the `:managed_identity` option."
  @spec bearer(String.t(), String.t(), keyword()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, Destination.failure()}
  def bearer(client_id, resource, opts)
      when is_binary(client_id) and is_binary(resource) and is_list(opts) do
    case Keyword.get(opts, :managed_identity) do
      identity when is_function(identity, 2) -> header(identity.(client_id, resource))
      _missing -> Cloud.unattempted(:credentials, "managed_identity_unavailable")
    end
  end

  defp header({:ok, token}) do
    if Redacted.redacted?(token) and is_binary(Redacted.expose(token)),
      do: {:ok, [{"authorization", "Bearer " <> Redacted.expose(token)}]},
      else: Cloud.unattempted(:credentials, "managed_identity_unavailable")
  end

  defp header({:error, %{class: _class, reason: _reason} = failure}), do: {:error, failure}
  defp header(_other), do: Cloud.unattempted(:credentials, "managed_identity_unavailable")
end
