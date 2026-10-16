defmodule Relay.Phone do
  @moduledoc """
  Phone numbers in E.164 form: `+`, a country code that does not start with zero and at most 15 digits in all. A Turkish number written with its trunk zero (`+900…`) is refused. The accepted number is a contact address and is returned wrapped in `Relay.Redacted`.
  """

  @e164 ~r/\A\+[1-9][0-9]{1,14}\z/

  # OP-1
  # T-58
  @doc "Validates an E.164 phone number and returns it redacted."
  @spec new(String.t() | Relay.Redacted.t()) ::
          {:ok, Relay.Redacted.t()} | {:error, Relay.Error.t()}
  def new(number) do
    if Relay.Redacted.redacted?(number),
      do: number |> Relay.Redacted.expose() |> validate(),
      else: validate(number)
  end

  defp validate(number) when is_binary(number) do
    cond do
      not Regex.match?(@e164, number) -> invalid("not an E.164 number")
      String.starts_with?(number, "+900") -> invalid("Turkish number with a trunk zero")
      true -> {:ok, Relay.Redacted.wrap(number)}
    end
  end

  defp validate(_other), do: invalid("not an E.164 number")

  defp invalid(message), do: {:error, Relay.Error.new(:invalid_phone, message)}
end
