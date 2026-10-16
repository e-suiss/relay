defmodule Relay.Locale do
  @moduledoc """
  BCP 47 language tags. A tag is accepted when it is well formed by the RFC 5646 `langtag` production without duplicate variants or extension singletons, and is returned in the RFC 5646 recommended letter case (`tr-TR`, `zh-Hant-TW`). Grandfathered tags and tags that consist only of a private use part are refused.
  """

  @type t :: String.t()

  @max_length 255

  # TN-2
  # C-57
  # TP-25
  @doc "Validates a BCP 47 language tag and returns it in canonical letter case."
  @spec new(term()) :: {:ok, t()} | {:error, Relay.Error.t()}
  def new(tag) when is_binary(tag) and byte_size(tag) in 1..@max_length do
    subtags = String.split(tag, "-")

    with true <- Enum.all?(subtags, &subtag?/1),
         {:ok, parts} <- parse(Enum.map(subtags, &String.downcase/1)) do
      {:ok, Enum.join(parts, "-")}
    else
      _ -> invalid()
    end
  end

  def new(_other), do: invalid()

  defp subtag?(subtag), do: byte_size(subtag) in 1..8 and alnum?(subtag)

  defp parse(subtags) do
    with {:ok, language, rest} <- language(subtags),
         {script, rest} <- script(rest),
         {region, rest} <- region(rest),
         {:ok, variants, rest} <- variants(rest, []),
         {:ok, extensions, rest} <- extensions(rest, [], []),
         {:ok, private, []} <- private_use(rest) do
      {:ok, language ++ script ++ region ++ variants ++ extensions ++ private}
    else
      _ -> :error
    end
  end

  defp language([language | rest]) do
    cond do
      alpha?(language) and byte_size(language) in 2..3 ->
        {extlangs, rest} = extlangs(rest, [])
        {:ok, [language | extlangs], rest}

      alpha?(language) and byte_size(language) in 4..8 ->
        {:ok, [language], rest}

      true ->
        :error
    end
  end

  defp extlangs([extlang | rest], acc) when length(acc) < 3 do
    if alpha?(extlang) and byte_size(extlang) == 3,
      do: extlangs(rest, [extlang | acc]),
      else: {Enum.reverse(acc), [extlang | rest]}
  end

  defp extlangs(rest, acc), do: {Enum.reverse(acc), rest}

  defp script([script | rest]) do
    if alpha?(script) and byte_size(script) == 4,
      do: {[String.capitalize(script)], rest},
      else: {[], [script | rest]}
  end

  defp script([]), do: {[], []}

  defp region([region | rest]) do
    cond do
      alpha?(region) and byte_size(region) == 2 -> {[String.upcase(region)], rest}
      digits?(region) and byte_size(region) == 3 -> {[region], rest}
      true -> {[], [region | rest]}
    end
  end

  defp region([]), do: {[], []}

  defp variants([variant | rest], acc) do
    cond do
      not variant?(variant) -> {:ok, Enum.reverse(acc), [variant | rest]}
      variant in acc -> :error
      true -> variants(rest, [variant | acc])
    end
  end

  defp variants([], acc), do: {:ok, Enum.reverse(acc), []}

  defp variant?(<<first, _::binary-3>>) when first in ?0..?9, do: true
  defp variant?(subtag), do: byte_size(subtag) in 5..8

  defp extensions([<<singleton>> | rest], seen, acc) when singleton != ?x do
    {body, rest} = Enum.split_while(rest, &(byte_size(&1) in 2..8))

    cond do
      singleton in seen -> :error
      body == [] -> :error
      true -> extensions(rest, [singleton | seen], acc ++ [<<singleton>> | body])
    end
  end

  defp extensions(rest, _seen, acc), do: {:ok, acc, rest}

  defp private_use(["x" | []]), do: :error
  defp private_use(["x" | body]), do: {:ok, ["x" | body], []}
  defp private_use(rest), do: {:ok, [], rest}

  defp alpha?(subtag), do: subtag |> :binary.bin_to_list() |> Enum.all?(&letter?/1)
  defp digits?(subtag), do: subtag |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9))

  defp alnum?(subtag),
    do: subtag |> :binary.bin_to_list() |> Enum.all?(&(letter?(&1) or &1 in ?0..?9))

  defp letter?(c), do: c in ?a..?z or c in ?A..?Z

  defp invalid, do: {:error, Relay.Error.new(:invalid_locale, "not a BCP 47 language tag")}
end
