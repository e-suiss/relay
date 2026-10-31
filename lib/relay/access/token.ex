defmodule Relay.Access.Token do
  @moduledoc """
  Verification of an Access access token on every request (API-71): the signature under the cached Access keys (`Relay.Access.Jose`), `iss` equal to the linked issuer, `aud` naming the expected Relay audience, `exp` and `nbf` with a clock tolerance of 60 seconds (S-68). Text comparisons of the issuer and the audience take constant time (API-47).

  A token that fails any check is `auth_invalid_token`, one past its `exp` is `auth_expired_token`.
  """

  alias Relay.Access.Jose

  @leeway_s 60

  @type expectation :: %{issuer: String.t(), audience: String.t(), now: integer()}

  # API-71
  # API-47
  @doc "Verifies a token's signature and claims and returns its claims."
  @spec verify(String.t(), [Jose.key()], expectation()) ::
          {:ok, map()} | {:error, Relay.Error.t()} | {:error, :unknown_key}
  def verify(token, keys, expectation) do
    case Jose.verify(token, keys) do
      {:ok, _header, claims} -> check(claims, expectation)
      {:error, :unknown_key} -> {:error, :unknown_key}
      {:error, _failure} -> invalid("the token signature or algorithm is not valid")
    end
  end

  # API-71
  @doc "Checks the issuer, audience, expiry and not-before claims of verified claims."
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

      not_yet?(claims["nbf"], now) ->
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
