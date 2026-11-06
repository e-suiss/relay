defmodule Relay.Access.SecurityEvent do
  @moduledoc """
  Access events as Security Event Tokens pushed with the Shared Signals Framework (E-94, RFC 8417, RFC 8935). A SET is a compact JWS whose header `typ` is `secevent+jwt`, signed by a key of the Access realm key set under an algorithm `Relay.Access.Jose` allows; its claims name the linked Access issuer as `iss`, Relay's Access `client_id` in `aud`, an `iat` at most 305 seconds old and at most 60 seconds ahead of the node's clock, a `jti` of 1 to 255 base64url characters and exactly one member of `events`, keyed `urn:suiss:access:event:<type>`. Relay shares no secret with Access. Every refusal is an RFC 8935 error code with a description.

  The event's data is its `events` member, with the names Access uses read as Relay's (E-80): `tenant` as `access_tenant_id`, `organization` as `access_organization_id` and `client_id` as `access_client_id`. The signed `access_tenant` claim of a platform product subscription names the tenant when the member does not; a member naming another tenant is refused.
  """

  alias Relay.Access.Jose
  alias Relay.Access.Token

  @prefix "urn:suiss:access:event:"
  @types ["secevent+jwt", "application/secevent+jwt"]
  @max_age_s 305
  @skew_s 60
  @jti ~r/\A[A-Za-z0-9_-]{1,255}\z/
  @renames [
    {"tenant", "access_tenant_id"},
    {"organization", "access_organization_id"},
    {"client_id", "access_client_id"}
  ]

  @type refusal :: {:refused, String.t(), String.t()}
  @type event :: %{jti: String.t(), type: String.t(), data: map()}
  @type expectation :: %{issuer: String.t(), audience: String.t(), now: integer()}

  # E-94
  @doc "Verifies a SET under the Access keys at Unix time `now` and returns its event; a `kid` the keys do not hold is `{:error, :unknown_key}`."
  @spec verify(String.t(), [Jose.key()], expectation()) ::
          {:ok, event()} | {:error, :unknown_key} | {:error, refusal()}
  def verify(token, keys, expectation) when is_binary(token) do
    with :ok <- header(token),
         {:ok, claims} <- signed(token, keys) do
      claims(claims, expectation)
    end
  end

  # E-94
  @doc "An RFC 8935 refusal."
  @spec refuse(String.t(), String.t()) :: {:error, refusal()}
  def refuse(err, description), do: {:error, {:refused, err, description}}

  defp header(token) do
    with {:ok, %{"typ" => typ}} when is_binary(typ) <- Jose.peek_header(token),
         true <- String.downcase(typ) in @types do
      :ok
    else
      {:error, :malformed} -> refuse("invalid_request", "the SET is not a compact JWS")
      _other -> refuse("invalid_request", "the JOSE typ is not secevent+jwt")
    end
  end

  defp signed(token, keys) do
    case Jose.verify(token, keys) do
      {:ok, _header, claims} -> {:ok, claims}
      {:error, :unknown_key} -> {:error, :unknown_key}
      {:error, :malformed} -> refuse("invalid_request", "the SET is not a compact JWS")
      {:error, :algorithm} -> refuse("invalid_request", "the SET algorithm is not allowed")
      {:error, :signature} -> refuse("authentication_failed", "the SET signature is not valid")
    end
  end

  defp claims(claims, %{issuer: issuer, audience: audience, now: now}) do
    cond do
      not Token.same?(claims["iss"], issuer) ->
        refuse("invalid_issuer", "the SET is not issued by the linked Access issuer")

      not audience?(claims["aud"], audience) ->
        refuse("invalid_audience", "the SET is not addressed to Relay")

      not fresh?(claims["iat"], now) ->
        refuse("invalid_request", "the SET iat is outside the accepted window")

      not jti?(claims["jti"]) ->
        refuse("invalid_request", "the SET has no valid jti")

      true ->
        event(claims)
    end
  end

  defp audience?(aud, expected) when is_binary(aud), do: Token.same?(aud, expected)

  defp audience?(aud, expected) when is_list(aud),
    do: Enum.reduce(aud, false, &(Token.same?(&1, expected) or &2))

  defp audience?(_aud, _expected), do: false

  defp fresh?(iat, now) when is_integer(iat), do: now - iat <= @max_age_s and iat - now <= @skew_s
  defp fresh?(_iat, _now), do: false

  defp jti?(jti) when is_binary(jti), do: Regex.match?(@jti, jti)
  defp jti?(_jti), do: false

  defp event(%{"events" => events} = claims) when is_map(events) and map_size(events) == 1 do
    [{urn, member}] = Map.to_list(events)

    with {:ok, type} <- type(urn),
         {:ok, data} <- data(member, claims["access_tenant"]) do
      {:ok, %{jti: claims["jti"], type: type, data: data}}
    end
  end

  defp event(_claims), do: refuse("invalid_request", "the SET must carry exactly one event")

  defp type(@prefix <> type) when type != "", do: {:ok, type}
  defp type(_urn), do: refuse("invalid_request", "the event type is not an Access event")

  # E-80
  defp data(member, tenant) when is_map(member) do
    data = Enum.reduce(@renames, member, &rename/2)

    case {data["access_tenant_id"], tenant} do
      {_named, nil} -> {:ok, data}
      {nil, claimed} when is_binary(claimed) -> {:ok, Map.put(data, "access_tenant_id", claimed)}
      {^tenant, _claimed} -> {:ok, data}
      _other -> refuse("invalid_request", "the event names another tenant than access_tenant")
    end
  end

  defp data(_member, _tenant), do: refuse("invalid_request", "the event is not an object")

  defp rename({from, to}, data) do
    case data do
      %{^from => value} when not is_map_key(data, to) ->
        data |> Map.delete(from) |> Map.put(to, value)

      _other ->
        data
    end
  end
end
