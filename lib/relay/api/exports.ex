defmodule Relay.Api.Exports do
  @moduledoc """
  Raw data exports on the server API (DS-37, OP-39, L-57, TN-18): a tenant asks for the CSV of its deliveries, its delivery ledger or its usage records for UTC days `from` to `to` (exclusive, at most 92 days); the request is audited as `export.requested`, answered `202` and written by a job. A ready export shows a signed download path that expires with the export; the download needs no credential, checks the export again and is audited as `export.downloaded`. Parquet is not offered.
  """

  alias Relay.Api.Page
  alias Relay.Api.Views

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @prefix "exp"
  @max_days 92
  @download "/exports/"

  @doc "The external identifier prefix of an export."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  # DS-37
  @doc "The API view of an export row; a ready export carries its signed download path."
  @spec view(Relay.Scope.t(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def view(scope, e) do
    with {:ok, path} <- download_path(scope, e) do
      {:ok,
       %{
         "object" => "export",
         "id" => Views.id(@prefix, e["id"]),
         "kind" => e["kind"],
         "format" => e["format"],
         "from" => Date.to_iso8601(e["period_start"]),
         "to" => Date.to_iso8601(e["period_end"]),
         "state" => e["state"],
         "failure" => e["failure"],
         "row_count" => e["row_count"],
         "byte_size" => e["byte_size"],
         "sha256" => e["content_sha256"] && Base.encode16(e["content_sha256"], case: :lower),
         "download_path" => path,
         "expires_at" => e["expires_at"],
         "completed_at" => e["completed_at"],
         "created_at" => e["created_at"]
       }}
    end
  end

  defp download_path(scope, %{"state" => "ready"} = e) do
    case Relay.Delivery.export_link(scope, e["id"], e["expires_at"]) do
      {:ok, token} -> {:ok, @download <> token}
      {:error, _error} -> {:error, unavailable()}
    end
  end

  defp download_path(_scope, _export), do: {:ok, nil}

  # DS-37
  @doc "Records an export request inside the request's transaction and queues its job; `202` with its view."
  @spec create(Relay.Scope.t(), map(), Relay.Actor.t()) :: answer()
  def create(scope, body, actor) do
    id = Relay.Id.generate()

    with {:ok, from} <- date(body["from"], "/from"),
         {:ok, to} <- date(body["to"], "/to"),
         :ok <- period(from, to),
         attrs = %{id: id, kind: body["kind"], period_start: from, period_end: to},
         :requested <- Relay.Delivery.request_export(scope, attrs, digest(scope, id), actor),
         {:ok, view} <- view(scope, Relay.Delivery.export(id)) do
      location = [{"location", "/v1/exports/" <> Relay.ExternalId.encode(@prefix, id)}]
      {:ok, {202, location, view}}
    end
  end

  # API-56
  @doc "Lists exports newest first, in pages."
  @spec list(Relay.Scope.t(), Relay.Api.Pagination.page(), String.t()) :: answer()
  def list(scope, page, endpoint) do
    position = &{&1["created_at"], &1["id"]}

    with {:ok, rows} <- read(Relay.Delivery.list_exports(scope, page.cursor, page.limit)),
         {:ok, views} <- views(scope, rows),
         render = &Map.fetch!(views, &1["id"]),
         {:ok, body} <- Page.envelope(rows, page, scope, endpoint, render, position) do
      {:ok, {200, [], body}}
    end
  end

  defp views(scope, rows) do
    Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, acc} ->
      case view(scope, row) do
        {:ok, view} -> {:cont, {:ok, Map.put(acc, row["id"], view)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc "Reads an export in its own scoped transaction."
  @spec get(Relay.Scope.t(), Relay.Id.t()) :: answer()
  def get(scope, id) do
    with {:ok, row} <- read(Relay.Delivery.get_export(scope, id)),
         {:ok, row} <- found(row),
         {:ok, view} <- view(scope, row) do
      {:ok, {200, [], view}}
    end
  end

  # DS-37
  # TN-18
  @doc "Downloads the export a signed token names: `{:ok, {filename, content}}`, or `:not_found` for a token that is not valid and `:gone` for one that expired, an export that expired or one that is not ready."
  @spec download(String.t()) ::
          {:ok, {String.t(), binary()}} | {:error, :not_found | :gone | Relay.Error.t()}
  def download(token) do
    with {:ok, %{scope: scope, id: id}} <- verified(token),
         {:ok, actor} <- Relay.Actor.new(:system, "export_link", "export_link"),
         digest = digest(scope, id),
         {:ok, {:ready, export, content}} <- downloaded(scope, id, digest, actor) do
      {:ok, {filename(export), content}}
    end
  end

  defp verified(token) do
    case Relay.Delivery.verify_export_link(token) do
      {:ok, claims} -> {:ok, claims}
      {:error, :invalid} -> {:error, :not_found}
      {:error, :expired} -> {:error, :gone}
      {:error, _key_store} -> {:error, unavailable()}
    end
  end

  defp downloaded(scope, id, digest, actor) do
    case Relay.Delivery.download_export(scope, id, digest, actor) do
      {:ok, {:ready, _export, _content}} = ready -> ready
      {:ok, :not_found} -> {:error, :not_found}
      {:ok, _expired_or_not_ready} -> {:error, :gone}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp filename(export) do
    from = Date.to_iso8601(export["period_start"])
    to = Date.to_iso8601(export["period_end"])
    "relay-#{export["kind"]}-#{from}-#{to}.csv"
  end

  @doc "The error of an unknown export."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:export_not_found, "no export has this id")

  defp found(nil), do: {:error, not_found()}
  defp found(row), do: {:ok, row}

  defp read({:ok, value}), do: {:ok, value}
  defp read({:error, _reason}), do: {:error, unavailable()}

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})

  defp date(text, pointer) do
    case Date.from_iso8601(text || "") do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> field(pointer, "invalid_format", "not a date")
    end
  end

  defp period(from, to) do
    days = Date.diff(to, from)

    cond do
      days < 1 -> field("/to", "not_allowed", "the period ends after it starts")
      days > @max_days -> field("/to", "not_allowed", "an export covers at most 92 days")
      true -> :ok
    end
  end

  defp digest(scope, id) do
    environment = Atom.to_string(scope.environment)
    parts = ["export", {:bytes, scope.tenant_id}, environment, Relay.Id.to_string(id)]
    :crypto.hash(:sha256, Relay.Canonical.encode!(parts))
  end

  defp field(pointer, code, detail) do
    {:error,
     Relay.Error.new(:validation_failed, detail, %{
       errors: [%{pointer: pointer, code: code, detail: detail}]
     })}
  end
end
