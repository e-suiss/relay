defmodule Relay.Api.Brand do
  @moduledoc """
  The brand fields (`brand.*`) of the server API (TP-35, TP-36, TP-48): read the effective fields of the tenant level or of a sub-tenant, each with the level it comes from, and change them with a JSON Merge Patch, where `null` clears a field at that level so a sub-tenant inherits the tenant's again. Every changed field is a `setting.changed` audit record.

  The ETag of a level is one more than the sum of the versions of the brand settings stored at that level, which grows with every change; an `If-Match` naming another value is `412`.
  """

  alias Relay.Actor
  alias Relay.Api.Gate
  alias Relay.Api.Views
  alias Relay.TemplateStore

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # TP-36
  @doc "The API view of the brand fields of a level."
  @spec view(Relay.Id.t() | nil, map()) :: map()
  def view(subtenant_id, fields) do
    %{
      "object" => "brand",
      "subtenant" => Views.id("stn", subtenant_id),
      "fields" =>
        Map.new(fields, fn {field, %{value: value, source: source}} ->
          {field, %{"value" => value, "source" => source(source)}}
        end)
    }
  end

  defp source(source) when source in ["subtenant", "tenant"], do: source
  defp source(_none), do: "none"

  @doc "The ETag header of a brand level."
  @spec etag(non_neg_integer()) :: {String.t(), String.t()}
  def etag(sum), do: {"etag", ~s("#{sum + 1}")}

  # TP-36
  @doc "Reads the brand fields of a level."
  @spec get(Relay.Scope.t(), Relay.Id.t() | nil) :: answer()
  def get(scope, subtenant_id) do
    read =
      TemplateStore.in_scope(scope, fn _status ->
        with :ok <- subtenant(subtenant_id), do: {:ok, TemplateStore.brand(subtenant_id)}
      end)

    case read do
      {:ok, {:ok, {fields, sum}}} -> {:ok, {200, [etag(sum)], view(subtenant_id, fields)}}
      {:ok, {:error, error}} -> {:error, error}
      {:error, _reason} -> {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  # TP-35
  # TP-36
  @doc "Applies a JSON Merge Patch of brand fields to a level inside the request's transaction; `expected` is the ETag value of `If-Match`, or `nil`."
  @spec update(Relay.Scope.t(), Relay.Id.t() | nil, map(), pos_integer() | nil, Actor.t()) ::
          answer()
  def update(scope, subtenant_id, body, expected, actor) do
    with :ok <- check(body),
         :ok <- subtenant(subtenant_id),
         :ok <- current(subtenant_id, expected),
         :ok <- write(scope, subtenant_id, body, actor) do
      {fields, sum} = TemplateStore.brand(subtenant_id)
      {:ok, {200, [etag(sum)], view(subtenant_id, fields)}}
    end
  end

  defp check(body) do
    case body["logo_url"] do
      url when is_binary(url) ->
        if https?(url),
          do: :ok,
          else: {:error, Gate.field_error("/logo_url", "invalid_format", "an https URL")}

      _other ->
        :ok
    end
  end

  defp https?(url) do
    match?(%URI{scheme: "https", host: host} when is_binary(host) and host != "", URI.parse(url))
  end

  defp subtenant(nil), do: :ok

  defp subtenant(id) do
    if TemplateStore.subtenant?(id),
      do: :ok,
      else: {:error, Relay.Error.new(:subtenant_not_found, "no subtenant has this id")}
  end

  defp current(_subtenant_id, nil), do: :ok

  defp current(subtenant_id, expected) do
    {_fields, sum} = TemplateStore.brand(subtenant_id)

    if sum + 1 == expected,
      do: :ok,
      else: {:error, Relay.Error.new(:precondition_failed, "the brand changed; read it again")}
  end

  defp write(scope, subtenant_id, body, actor) do
    fields = TemplateStore.brand_fields()

    body
    |> Enum.filter(fn {field, _value} -> field in fields end)
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn {field, value}, :ok ->
      digest = Gate.digest(scope, "setting.changed", "brand." <> field)

      case TemplateStore.brand_put(subtenant_id, field, value, digest, actor) do
        :subtenant_not_found ->
          {:halt, {:error, Relay.Error.new(:subtenant_not_found, "no subtenant has this id")}}

        _written ->
          {:cont, :ok}
      end
    end)
  end
end
