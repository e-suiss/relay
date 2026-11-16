defmodule Relay.Api.ProviderInvoices do
  @moduledoc """
  Provider invoices on the server API (OP-38, OP-42, CH-18): a tenant records the invoice a provider sent for one of its accounts, with its period, currency, amount in micros and the raw invoice object, and reads it back with its reconciliation against the immutable usage records of the period. An invoice never changes; the same provider and reference again with the same figures answers the recorded invoice, with other figures `409 resource_conflict`. The write runs inside the request's transaction and is audited as `provider_invoice.recorded`.
  """

  alias Relay.Api.Page
  alias Relay.Api.Views

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @prefix "piv"
  @max_days 92
  @max_micros 9_223_372_036_854_775_807
  @max_raw 65_536

  @doc "The external identifier prefix of a provider invoice."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  # OP-42
  @doc "The API view of an invoice row with its reconciliation."
  @spec view(map()) :: map()
  def view(i) do
    %{
      "object" => "provider_invoice",
      "id" => Views.id(@prefix, i["id"]),
      "provider" => i["provider"],
      "channel" => i["channel"],
      "invoice_ref" => i["invoice_ref"],
      "period_start" => Date.to_iso8601(i["period_start"]),
      "period_end" => Date.to_iso8601(i["period_end"]),
      "currency" => i["currency"],
      "amount_micros" => Integer.to_string(i["amount_micros"]),
      "units" => i["units"],
      "raw" => i["raw"],
      "reconciliation" => reconciliation(i),
      "created_at" => i["created_at"]
    }
  end

  defp reconciliation(%{"checked_at" => nil}), do: nil

  defp reconciliation(i) do
    %{
      "checked_at" => i["checked_at"],
      "result" => i["check_result"],
      "usage_cost_micros" => Integer.to_string(i["usage_cost_micros"]),
      "usage_units" => i["usage_units"],
      "unpriced_units" => i["unpriced_units"],
      "drift_micros" => Integer.to_string(i["drift_micros"]),
      "drift_bp" => i["drift_bp"]
    }
  end

  # OP-38
  # OP-42
  @doc "Records a provider invoice inside the request's transaction and reconciles it; `201` with its view, `200` when the same invoice was recorded before."
  @spec create(Relay.Scope.t(), map(), Relay.Actor.t()) :: answer()
  def create(scope, body, actor) do
    with {:ok, period_start} <- date(body["period_start"], "/period_start"),
         {:ok, period_end} <- date(body["period_end"], "/period_end"),
         :ok <- period(period_start, period_end),
         {:ok, amount} <- micros(body["amount_micros"]),
         :ok <- raw(body["raw"]) do
      id = Relay.Id.generate()

      attrs = %{
        id: id,
        provider: body["provider"],
        channel: body["channel"],
        invoice_ref: body["invoice_ref"],
        period_start: period_start,
        period_end: period_end,
        currency: body["currency"],
        amount_micros: amount,
        units: body["units"],
        raw: body["raw"]
      }

      digest = digest(scope, id)

      case Relay.Delivery.record_invoice(scope, attrs, digest, actor) do
        {:recorded, id} -> answer(id, 201)
        {:exists, id} -> answer(id, 200)
        {:conflict, _id} -> {:error, conflict()}
      end
    end
  end

  defp answer(id, status) do
    location = [{"location", "/v1/provider_invoices/" <> Relay.ExternalId.encode(@prefix, id)}]
    headers = if status == 201, do: location, else: []
    {:ok, {status, headers, view(Relay.Delivery.invoice(id))}}
  end

  # API-56
  @doc "Lists provider invoices newest first, in pages."
  @spec list(Relay.Scope.t(), Relay.Api.Pagination.page(), String.t()) :: answer()
  def list(scope, page, endpoint) do
    position = &{&1["created_at"], &1["id"]}

    with {:ok, rows} <- read(Relay.Delivery.list_invoices(scope, page.cursor, page.limit)),
         {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &view/1, position) do
      {:ok, {200, [], body}}
    end
  end

  @doc "Reads a provider invoice in its own scoped transaction."
  @spec get(Relay.Scope.t(), Relay.Id.t()) :: answer()
  def get(scope, id) do
    case read(Relay.Delivery.get_invoice(scope, id)) do
      {:ok, nil} -> {:error, not_found()}
      {:ok, row} -> {:ok, {200, [], view(row)}}
      {:error, error} -> {:error, error}
    end
  end

  @doc "The error of an unknown provider invoice."
  @spec not_found() :: Relay.Error.t()
  def not_found,
    do: Relay.Error.new(:provider_invoice_not_found, "no provider invoice has this id")

  defp read({:ok, value}), do: {:ok, value}

  defp read({:error, _reason}),
    do: {:error, Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})}

  defp date(text, pointer) do
    case Date.from_iso8601(text || "") do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> field(pointer, "invalid_format", "not a date")
    end
  end

  defp period(from, to) do
    days = Date.diff(to, from)

    cond do
      days < 1 -> field("/period_end", "not_allowed", "the period ends after it starts")
      days > @max_days -> field("/period_end", "not_allowed", "a period is at most 92 days")
      true -> :ok
    end
  end

  defp micros(text) do
    case Integer.parse(text || "") do
      {n, ""} when n >= 0 and n <= @max_micros -> {:ok, n}
      _invalid -> field("/amount_micros", "invalid_format", "not an amount in micros")
    end
  end

  defp raw(nil), do: :ok

  defp raw(raw) do
    if byte_size(Jason.encode!(raw)) <= @max_raw,
      do: :ok,
      else: field("/raw", "too_long", "the raw invoice is at most 64 KiB")
  end

  defp digest(scope, id) do
    environment = Atom.to_string(scope.environment)
    ref = Relay.Id.to_string(id)
    parts = ["provider_invoice.recorded", {:bytes, scope.tenant_id}, environment, ref]
    :crypto.hash(:sha256, Relay.Canonical.encode!(parts))
  end

  defp conflict,
    do: Relay.Error.new(:resource_conflict, "this invoice reference has other figures")

  defp field(pointer, code, detail) do
    {:error,
     Relay.Error.new(:validation_failed, detail, %{
       errors: [%{pointer: pointer, code: code, detail: detail}]
     })}
  end
end
