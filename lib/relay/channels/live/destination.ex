defmodule Relay.Channels.Live.Destination do
  @moduledoc """
  The destination protections in the channel step (CH-54, E-33, TN-52 (2)): every `security` SMS a real provider is about to send is first shown to `Relay.DestinationGuard`, after the provider limits allowed it and before its attempt opens, so a stopped delivery opens no attempt, costs nothing and is recorded skipped with the rule that stopped it. The fake provider of the test plane and of shadow mode sends nothing and is not guarded.

  The number is counted under its blind index, never under the number itself, and only on the delivery's first attempt: a retry of a delivery that was already counted checks the allow-list and the stops again and adds nothing to the counters. A number the protections cannot place is not on any allow-list. An input that cannot be read is an error: the job retries and nothing is sent (INV-43).
  """

  alias Relay.Scope

  @type decision :: :ok | {:skip, String.t()} | {:error, term()}

  # CH-54
  # TN-52 (2)
  @doc "Returns true when a delivery through `account` is a `security` SMS the protections apply to."
  @spec guarded?(map(), map()) :: boolean()
  def guarded?(%{"channel" => "sms", "message_class" => "security"}, %{"provider" => provider}),
    do: provider != "fake"

  def guarded?(_delivery, _account), do: false

  # CH-54
  # E-33
  # TN-52 (2)
  # INV-43
  @doc "Decides whether the delivery may be sent to `number`; `:ok` for a delivery the protections do not apply to."
  @spec admit(Scope.t(), map(), map(), term()) :: decision()
  def admit(%Scope{} = scope, delivery, account, number) do
    cond do
      not guarded?(delivery, account) -> :ok
      not Relay.DestinationGuard.number?(number) -> {:skip, "destination.country_not_allowed"}
      true -> guard(scope, delivery, number)
    end
  end

  defp guard(scope, delivery, number) do
    index = %{tenant_id: scope.tenant_id, environment: scope.environment, purpose: "address"}

    case Relay.Tenancy.blind_index(index, number) do
      {:ok, {_key_id, digest}} ->
        request = %{
          number: number,
          number_key: Base.encode16(digest, case: :lower),
          count?: delivery["attempt_count"] in [nil, 0]
        }

        Relay.DestinationGuard.admit(scope, request)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
