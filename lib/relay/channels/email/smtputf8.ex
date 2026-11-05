defmodule Relay.Channels.Email.Smtputf8 do
  @moduledoc """
  Internationalized addresses (CH-45, RFC 6531). An address with a non-ASCII character in its local part or domain is never refused: it needs the `SMTPUTF8` extension, and a provider that does not support it fails the delivery with an explicit `permanent_content` error instead of the address being rewritten or dropped.
  """

  alias Relay.Error

  # CH-45
  @doc "Whether an address needs `SMTPUTF8`: it carries a byte outside ASCII."
  @spec required?(String.t()) :: boolean()
  def required?(address) when is_binary(address),
    do: address |> :binary.bin_to_list() |> Enum.any?(&(&1 > 127))

  # CH-45
  @doc "Checks the envelope and header addresses of an e-mail against the provider's `SMTPUTF8` support: `{:ok, false}` when none needs it, `{:ok, true}` when one does and the provider supports it, otherwise the `permanent_content` error `smtputf8_unsupported`."
  @spec check([String.t()], boolean()) :: {:ok, boolean()} | {:error, Error.t()}
  def check(addresses, provider_supports?) when is_list(addresses) do
    case {Enum.any?(addresses, &required?/1), provider_supports?} do
      {false, _supports} ->
        {:ok, false}

      {true, true} ->
        {:ok, true}

      {true, false} ->
        {:error,
         Error.new(
           :smtputf8_unsupported,
           "the address needs SMTPUTF8 and the provider does not support it",
           %{failure_class: "permanent_content"}
         )}
    end
  end
end
