defmodule Relay.Access.Token do
  @moduledoc """
  Verification of an Access access token on every request (API-71, E-93): the signature under the cached Access keys (`Relay.Access.Jose`), the header `typ` when the expectation names one (`at+jwt` for an Access access token), `iss` equal to the linked issuer, `aud` naming the expected Relay audience, `exp`, `nbf` and `iat` with a clock tolerance of 60 seconds (S-68). Text comparisons of the issuer and the audience take constant time (API-47).

  A token that fails any check is `auth_invalid_token`, one past its `exp` is `auth_expired_token`.
  """

  alias Relay.Access.Jose

  @leeway_s 60

  @type expectation :: %{
          required(:issuer) => String.t(),
          required(:audience) => String.t(),
          required(:now) => integer(),
          optional(:typ) => String.t()
        }

  # API-71
  # API-47
  # E-93
  @doc "Verifies a token's signature, header type and claims and returns its claims."
  @spec verify(String.t(), [Jose.key()], expectation()) ::
          {:ok, map()} | {:error, Relay.Error.t()} | {:error, :unknown_key}
  def verify(token, keys, expectation) do
    case Jose.verify(token, keys) do
      {:ok, header, claims} -> typed(header, claims, expectation)
      {:error, :unknown_key} -> {:error, :unknown_key}
      {:error, _failure} -> invalid("the token signature or algorithm is not valid")
    end
  end

  defp typed(%{"typ" => typ}, claims, %{typ: typ} = expectation), do: check(claims, expectation)
  defp typed(_header, _claims, %{typ: _typ}), do: invalid("the token is not an access token")
  defp typed(_header, claims, expectation), do: check(claims, expectation)

  # API-71
  # E-93
  @doc "Checks the issuer, audience, expiry, not-before and issued-at claims of verified claims."
  @spec check(map(), expectation()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def check(claims, %{issuer: issuer, audience: audience, now: now}) do
    cond do
      not same?(claims["iss"], issuer) ->
        invalid("the token is not issued by the linked Access issuer")

      not audience?(claims["aud"], audience) ->
        invalid("the token is not issued for this API")

      not is_integer(claims["exp"]) ->
        invalid("the token has no expiry")

      now > claims["exp"] + @leeway_s ->
        {:error, Relay.Error.new(:auth_expired_token, "the token has expired")}

      not_yet?(claims["nbf"], now) or not_yet?(claims["iat"], now) ->
        invalid("the token is not valid yet")

      true ->
        {:ok, claims}
    end
  end

  defp not_yet?(nil, _now), do: false
  defp not_yet?(nbf, now) when is_integer(nbf), do: now + @leeway_s < nbf
  defp not_yet?(_nbf, _now), do: true

  defp audience?(aud, expected) when is_binary(aud), do: same?(aud, expected)

  defp audience?(aud, expected) when is_list(aud),
    do: Enum.reduce(aud, false, &(same?(&1, expected) or &2))

  defp audience?(_aud, _expected), do: false

  # API-47
  @doc "Compares two texts in constant time."
  @spec same?(term(), term()) :: boolean()
  def same?(a, b) when is_binary(a) and is_binary(b),
    do: :crypto.hash_equals(:crypto.hash(:sha256, a), :crypto.hash(:sha256, b))

  def same?(_a, _b), do: false

  defp invalid(message), do: {:error, Relay.Error.new(:auth_invalid_token, message)}
end
