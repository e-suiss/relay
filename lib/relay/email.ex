defmodule Relay.Email do
  @moduledoc """
  E-mail addresses in normalized text form. Normalization trims surrounding white space, applies Unicode NFC and lowercases the domain; the local part keeps its case. Quoted local parts and address literals are refused. The accepted address is a contact address and is returned wrapped in `Relay.Redacted`.
  """

  @max_address 254
  @max_local 64
  @max_domain 253
  @max_label 63
  @local_specials ~c"!#$%&'*+-/=?^_`{|}~"
  @ascii_label ~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/

  # OP-1
  # T-58
  @doc "Validates and normalizes an e-mail address and returns it redacted."
  @spec new(String.t() | Relay.Redacted.t()) ::
          {:ok, Relay.Redacted.t()} | {:error, Relay.Error.t()}
  def new(address) do
    if Relay.Redacted.redacted?(address),
      do: address |> Relay.Redacted.expose() |> normalize(),
      else: normalize(address)
  end

  defp normalize(address) when is_binary(address) do
    with true <- String.valid?(address),
         normalized = address |> String.trim() |> :unicode.characters_to_nfc_binary(),
         true <- is_binary(normalized),
         [local, domain] <- String.split(normalized, "@"),
         domain = String.downcase(domain),
         true <- local?(local),
         true <- domain?(domain),
         result = local <> "@" <> domain,
         true <- byte_size(result) <= @max_address do
      {:ok, Relay.Redacted.wrap(result)}
    else
      _ -> invalid()
    end
  end

  defp normalize(_other), do: invalid()

  defp local?(local) do
    byte_size(local) in 1..@max_local and
      not String.starts_with?(local, ".") and
      not String.ends_with?(local, ".") and
      not String.contains?(local, "..") and
      local |> String.to_charlist() |> Enum.all?(&local_char?/1)
  end

  defp local_char?(c) when c in ?a..?z or c in ?A..?Z or c in ?0..?9, do: true
  defp local_char?(c) when c in @local_specials or c == ?., do: true
  defp local_char?(c) when c > 127, do: not whitespace_or_control?(c)
  defp local_char?(_c), do: false

  defp domain?(domain) do
    labels = String.split(domain, ".")

    byte_size(domain) in 1..@max_domain and length(labels) >= 2 and
      Enum.all?(labels, &label?/1)
  end

  defp label?(label) do
    cond do
      byte_size(label) not in 1..@max_label -> false
      ascii?(label) -> Regex.match?(@ascii_label, label)
      true -> unicode_label?(label)
    end
  end

  defp unicode_label?(label) do
    chars = String.to_charlist(label)

    hd(chars) != ?- and List.last(chars) != ?- and
      Enum.all?(chars, fn c ->
        c in ?a..?z or c in ?0..?9 or c == ?- or (c > 127 and not whitespace_or_control?(c))
      end)
  end

  defp ascii?(binary), do: binary |> :binary.bin_to_list() |> Enum.all?(&(&1 < 128))

  defp whitespace_or_control?(c),
    do:
      c in 0x80..0x9F or c in [0xA0, 0x1680, 0x2028, 0x2029, 0x3000, 0xFEFF] or
        c in 0x2000..0x200B

  defp invalid, do: {:error, Relay.Error.new(:invalid_email, "not a valid e-mail address")}
end
