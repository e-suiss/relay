defmodule Relay.Api.ErrorCatalog do
  @moduledoc """
  The single error catalog, read at compile time from `contracts/errors.yaml`. Problem documents, the error code pages (`GET /v1/errors/{code}`) and the limits page are fed from it; no code, title, status or retry rule is written anywhere else.
  """

  @path Path.expand("../../../contracts/errors.yaml", __DIR__)
  @external_resource @path

  @catalog YamlElixir.read_from_file!(@path)

  entries =
    Map.new(@catalog["codes"], fn entry ->
      {entry["code"],
       %{
         code: entry["code"],
         family: entry["family"],
         status: entry["status"],
         title: entry["title"],
         retryable: entry["retryable"],
         retry_after: %{
           kind: entry["retry_after"]["kind"],
           seconds: entry["retry_after"]["seconds"],
           max_seconds: entry["retry_after"]["max_seconds"]
         },
         extensions: entry["extensions"],
         description: entry["description"]
       }}
    end)

  @entries entries
  @field_error_codes @catalog["field_error_codes"]
  @retryable_defaults @catalog["retryable_defaults"]
  @type_path "/v1/errors/"

  @type entry :: %{
          code: String.t(),
          family: String.t(),
          status: 400..599,
          title: String.t(),
          retryable: boolean(),
          retry_after: %{
            kind: String.t(),
            seconds: non_neg_integer() | nil,
            max_seconds: non_neg_integer() | nil
          },
          extensions: [String.t()],
          description: String.t()
        }

  # API-40
  # API-73
  @doc "The catalog entry of a code, given as a string or an atom."
  @spec fetch(String.t() | atom()) :: {:ok, entry()} | :error
  def fetch(code) when is_atom(code), do: fetch(Atom.to_string(code))
  def fetch(code) when is_binary(code), do: Map.fetch(@entries, code)

  @doc "Every code of the catalog, sorted."
  @spec codes() :: [String.t()]
  def codes, do: @entries |> Map.keys() |> Enum.sort()

  # API-37
  @doc "The field error subcodes."
  @spec field_error_codes() :: [String.t()]
  def field_error_codes, do: @field_error_codes

  # API-38
  @doc "The status to `retryable` default table of the catalog."
  @spec retryable_defaults() :: [map()]
  def retryable_defaults, do: @retryable_defaults

  # API-73
  @doc "The resolvable problem `type` URL of a code on the region's base URL."
  @spec type_url(String.t(), String.t()) :: String.t()
  def type_url(base_url, code) when is_binary(base_url) and is_binary(code),
    do: String.trim_trailing(base_url, "/") <> @type_path <> code

  # API-73
  @doc "The error code page of `GET /v1/errors/{code}`."
  @spec describe(entry(), String.t()) :: map()
  def describe(entry, base_url) do
    %{
      "object" => "error_code",
      "code" => entry.code,
      "family" => entry.family,
      "type" => type_url(base_url, entry.code),
      "title" => entry.title,
      "status" => entry.status,
      "retryable" => entry.retryable,
      "retry_after" => %{
        "kind" => entry.retry_after.kind,
        "seconds" => entry.retry_after.seconds,
        "max_seconds" => entry.retry_after.max_seconds
      },
      "description" => entry.description
    }
  end
end
