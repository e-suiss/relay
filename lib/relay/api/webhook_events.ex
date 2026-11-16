defmodule Relay.Api.WebhookEvents do
  @moduledoc """
  The event feed of the development tunnel on the server API (WH-45 (2), API-64, X-33): Relay's own events of the environment, newest first, each with the thin CloudEvents envelope an endpoint without a snapshot receives (WH-8, WH-11). `relay listen --forward-to` reads it and forwards the envelopes to a local address; Relay itself never calls a developer machine and has no customer-defined bridge URL. The feed carries identifiers only, no personal data, and events of a tenant's own event types are not part of it.
  """

  alias Relay.Api.Page
  alias Relay.Api.Pagination
  alias Relay.Scope

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @name ~r/\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+\z/

  # WH-45 (2)
  @doc "The API view of an event row with its envelope."
  @spec view(map()) :: map()
  def view(e) do
    %{
      "object" => "webhook_event",
      "id" => e["envelope"]["id"],
      "type" => e["event_type"],
      "created_at" => e["created_at"],
      "envelope" => e["envelope"]
    }
  end

  # API-56
  @doc "Reads the `event_type` and `created_after` filters of a list request; every invalid one is reported."
  @spec filters(map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def filters(query) do
    checks = [{"event_type", :event_type, &name/1}, {"created_after", :created_after, &time/1}]

    {filters, errors} =
      Enum.reduce(checks, {%{}, []}, fn {name, field, check}, {acc, errors} ->
        case check.(Map.get(query, name)) do
          {:ok, nil} -> {acc, errors}
          {:ok, value} -> {Map.put(acc, field, value), errors}
          :error -> {acc, [invalid(name) | errors]}
        end
      end)

    if errors == [],
      do: {:ok, filters},
      else: {:error, Relay.Error.new(:validation_failed, "invalid filters", %{errors: errors})}
  end

  defp invalid(name), do: %{pointer: "/" <> name, code: "invalid_format", detail: name}

  defp name(nil), do: {:ok, nil}

  defp name(value) when is_binary(value) do
    if byte_size(value) <= 128 and Regex.match?(@name, value), do: {:ok, value}, else: :error
  end

  defp name(_value), do: :error

  defp time(nil), do: {:ok, nil}

  defp time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      _invalid -> :error
    end
  end

  defp time(_value), do: :error

  # WH-45 (2)
  # API-56
  @doc "Lists the events of the scope, newest first; an event whose envelope cannot be built is left out."
  @spec list(Scope.t(), map(), Pagination.page(), String.t()) :: answer()
  def list(%Scope{} = scope, filters, page, endpoint) do
    case Relay.Webhooks.list_events(scope, filters, page.cursor, page.limit) do
      {:ok, rows} ->
        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &view/1, &position/1) do
          {:ok, {200, [], Map.update!(body, "data", &built/1)}}
        end

      {:error, _reason} ->
        {:error, Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})}
    end
  end

  defp built(views), do: Enum.filter(views, &is_map(&1["envelope"]))

  defp position(row), do: {row["cursor_at"], row["id"]}
end
