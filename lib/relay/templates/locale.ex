defmodule Relay.Templates.Locale do
  @moduledoc """
  Locale resolution of a template cell (TP-25, TP-26).

  The recipient's locale is the first valid BCP 47 tag of: the profile, the device, and only for inbox and web requests the highest weighted `Accept-Language` range. When there is none, the tenant's `default_locale` is used. The cell is found by truncation (`tr-TR` → `tr`), then the tenant default by truncation; there is no system default. Falling back to the tenant default for a recipient who has a locale counts as `template_locale_missing`. When no cell matches, the render does not happen (`template.locale_missing`).
  """

  @type surface :: :send | :inbox | :web
  @type source :: :profile | :device | :accept_language | :tenant_default
  @type candidates :: %{
          optional(:profile) => String.t() | nil,
          optional(:device) => String.t() | nil,
          optional(:accept_language) => String.t() | nil,
          optional(:surface) => surface(),
          required(:tenant_default) => String.t()
        }
  @type resolution :: %{
          locale: String.t(),
          requested: String.t() | nil,
          source: source(),
          template_locale_missing: boolean()
        }

  @max_ranges 32

  # TP-25
  @doc "The recipient's locale and where it came from; `Accept-Language` counts only on the inbox and web surfaces."
  @spec recipient(candidates()) :: {:ok, String.t(), source()} | :error
  def recipient(candidates) when is_map(candidates) do
    accept =
      if Map.get(candidates, :surface, :send) in [:inbox, :web],
        do: candidates |> Map.get(:accept_language) |> accept_language() |> List.first(),
        else: nil

    [
      {Map.get(candidates, :profile), :profile},
      {Map.get(candidates, :device), :device},
      {accept, :accept_language},
      {Map.get(candidates, :tenant_default), :tenant_default}
    ]
    |> Enum.find_value(:error, fn {tag, source} ->
      case canonical(tag) do
        {:ok, tag} -> {:ok, tag, source}
        :error -> nil
      end
    end)
  end

  # TP-25
  # TP-26
  @doc "Chooses the template cell for a recipient among the cell locales of a template."
  @spec resolve(candidates(), [String.t()]) :: {:ok, resolution()} | {:error, :locale_missing}
  def resolve(candidates, cells) when is_map(candidates) and is_list(cells) do
    cells = for cell <- cells, {:ok, tag} <- [canonical(cell)], do: tag

    with {:ok, requested, source} <- recipient(candidates),
         {:ok, tenant} <- canonical(Map.get(candidates, :tenant_default)) do
      requested = if source == :tenant_default, do: nil, else: requested
      own = if requested, do: find(chain(requested), cells), else: nil
      tenant_cell = find(chain(tenant), cells)

      cond do
        own ->
          {:ok, resolution(own, requested, source, false)}

        tenant_cell ->
          {:ok, resolution(tenant_cell, requested, :tenant_default, requested != nil)}

        true ->
          {:error, :locale_missing}
      end
    else
      _ -> {:error, :locale_missing}
    end
  end

  defp resolution(locale, requested, source, missing),
    do: %{locale: locale, requested: requested, source: source, template_locale_missing: missing}

  defp find(chain, cells), do: Enum.find(chain, &(&1 in cells))

  # TP-26
  @doc "The truncation chain of a locale: `zh-Hant-TW` → `zh-Hant` → `zh`; a trailing single-letter subtag is dropped with its value."
  @spec chain(String.t()) :: [String.t()]
  def chain(locale) when is_binary(locale) do
    locale
    |> String.split("-")
    |> truncations([])
    |> Enum.map(&Enum.join(&1, "-"))
  end

  defp truncations([], acc), do: Enum.reverse(acc)

  defp truncations(subtags, acc) do
    rest = subtags |> Enum.drop(-1) |> drop_singleton()
    truncations(rest, [subtags | acc])
  end

  defp drop_singleton(subtags) do
    case List.last(subtags) do
      <<_>> -> Enum.drop(subtags, -1)
      _ -> subtags
    end
  end

  # TP-25
  @doc "The language ranges of an `Accept-Language` header by descending weight; wildcards and invalid ranges are left out."
  @spec accept_language(String.t() | nil) :: [String.t()]
  def accept_language(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.take(@max_ranges)
    |> Enum.with_index()
    |> Enum.flat_map(&range/1)
    |> Enum.sort_by(fn {_tag, weight, index} -> {-weight, index} end)
    |> Enum.map(fn {tag, _weight, _index} -> tag end)
  end

  def accept_language(_header), do: []

  defp range({part, index}) do
    [tag | params] = part |> String.split(";") |> Enum.map(&String.trim/1)

    with {:ok, tag} <- canonical(tag),
         {:ok, weight} <- weight(params),
         true <- weight > 0 do
      [{tag, weight, index}]
    else
      _ -> []
    end
  end

  defp weight([]), do: {:ok, 1.0}

  defp weight(["q=" <> value | _]) do
    case Float.parse(value) do
      {weight, ""} when weight >= 0 and weight <= 1 -> {:ok, weight}
      _ -> :error
    end
  end

  defp weight([_other | rest]), do: weight(rest)

  # TP-56
  @doc "Whether a locale's language is one of the supported locales of the CLDR backend."
  @spec supported?(String.t()) :: boolean()
  def supported?(locale) do
    case canonical(locale) do
      {:ok, tag} -> Relay.Templates.Cldr.language_tag(tag) != :error
      :error -> false
    end
  end

  defp canonical(tag) when is_binary(tag) do
    case Relay.Locale.new(tag) do
      {:ok, tag} -> {:ok, tag}
      {:error, _} -> :error
    end
  end

  defp canonical(_tag), do: :error
end
