defmodule Relay.Release.SubscriberTokenKey do
  @moduledoc """
  The subscriber token key release commands (IN-51): `bin/relay eval 'Relay.Release.SubscriberTokenKey.rotate(label: "subscriber-token-2027-03", operator: "…", reason: "…")'`.

  The new P-256 key pair is created in the key store first (`deploy/hsm-keys.sh` with `KEY_STORE_SUBSCRIBER_TOKEN_LABEL` set to the new label); `rotate/1` makes it the current key at once and the old key verifies for two token lifetimes more. `retire_previous/1` retires the previous key without waiting, on suspected compromise; its tokens stop verifying and the realtime layer closes their connections. `status/0` shows the current key, its activation and when the 90-day rotation (POLICY DEFAULT) is due. Every call names the operator (`operator:`) and a reason (`reason:`), which the key's row keeps. Results are `{:ok, map}` or `{:error, atom}`.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Access], exports: []

  # IN-51
  # TN-63
  @doc "Rotates to the key pair `label:`. Options: `label:`, `operator:` and `reason:`."
  @spec rotate(keyword()) :: {:ok, map()} | {:error, atom()}
  def rotate(opts) when is_list(opts) do
    with {:ok, label} <- text(opts, :label, :label_required),
         {:ok, operator} <- text(opts, :operator, :operator_required),
         {:ok, reason} <- text(opts, :reason, :reason_required),
         do: result(Relay.Access.rotate_subscriber_token_key(label, operator, reason))
  end

  # IN-51
  # IN-33
  @doc "Retires the previous key at once. Options: `operator:` and `reason:`."
  @spec retire_previous(keyword()) :: {:ok, map()} | {:error, atom()}
  def retire_previous(opts) when is_list(opts) do
    with {:ok, operator} <- text(opts, :operator, :operator_required),
         {:ok, reason} <- text(opts, :reason, :reason_required),
         do: result(Relay.Access.retire_previous_subscriber_token_key(operator, reason))
  end

  # IN-51
  @doc "Shows the current key, its activation, when its rotation is due and the previous key's window."
  @spec status() :: {:ok, map()} | {:error, atom()}
  def status, do: result(Relay.Access.subscriber_token_key_status())

  defp text(opts, name, missing) do
    case Keyword.get(opts, name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, missing}
    end
  end

  defp result({:ok, map}), do: {:ok, map}
  defp result({:error, %Relay.Error{code: code}}), do: {:error, code}
end
