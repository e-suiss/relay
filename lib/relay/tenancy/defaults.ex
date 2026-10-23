defmodule Relay.Tenancy.Defaults do
  @moduledoc """
  The tenant's default time zone and locale (TN-2). A time zone is an IANA zone and is stored under its canonical name, never a link name or an offset zone (TN-65 (6)); a locale is a BCP 47 tag in canonical letter case of the form the tenant table accepts (a two- or three-letter language and subtags of two to eight characters).
  """

  @locale ~r/\A[a-z]{2,3}(-[A-Za-z0-9]{2,8})*\z/

  @type field :: :default_timezone | :default_locale

  # TN-2
  # TN-65 (6)
  @doc "Replaces the given fields of `attrs` with their canonical forms; with `required: false` a missing or `nil` field is left as it is."
  @spec canonical(map(), [field()], keyword()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def canonical(attrs, fields, opts \\ []) when is_map(attrs) do
    required = Keyword.get(opts, :required, true)

    Enum.reduce_while(fields, {:ok, attrs}, fn field, {:ok, acc} ->
      case {Map.get(acc, field), required} do
        {nil, false} -> {:cont, {:ok, acc}}
        {value, _} -> put(acc, field, cast(field, value))
      end
    end)
  end

  defp put(acc, field, {:ok, canonical}), do: {:cont, {:ok, Map.put(acc, field, canonical)}}
  defp put(_acc, _field, {:error, error}), do: {:halt, {:error, error}}

  @doc "Validates one default and returns its canonical form."
  @spec cast(field(), term()) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  def cast(:default_timezone, value), do: Relay.TimeZone.new(value)

  def cast(:default_locale, value) do
    with {:ok, tag} <- Relay.Locale.new(value) do
      if Regex.match?(@locale, tag),
        do: {:ok, tag},
        else: {:error, Relay.Error.new(:invalid_locale, "not a supported default locale")}
    end
  end
end
