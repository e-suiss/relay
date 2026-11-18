defmodule Relay.Api.SubjectExport do
  @moduledoc """
  The export of one person's data (OP-26, OP-86): the subscriber as `getSubscriber` shows it and its delivery history, newest first, as JSON. At most `x-relay-limits` `subject_export.max_deliveries` deliveries are returned and `truncated` tells when older ones exist; their full history is in the raw data exports. The export is audited as `subject.exported` before any delivery is read.
  """

  alias Relay.Api.Store

  @max Relay.Limits.fetch!(["subject_export", "max_deliveries"])

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # OP-26
  # OP-86
  # TN-47
  @doc "Exports the subscriber with the external identifier `external_id` of `scope`; `digest` is the digest of its `subject.exported` audit record."
  @spec export(Relay.Scope.t(), String.t(), <<_::256>>, Relay.Actor.t()) :: answer()
  def export(scope, external_id, digest, actor) do
    with {:ok, view} <- subscriber(scope, external_id),
         id = view["_id"],
         :ok <- audit(scope, id, digest, actor),
         {:ok, rows} <- deliveries(scope, id) do
      {kept, more} = Enum.split(rows, @max)
      columns = Relay.Delivery.export_columns("deliveries")

      {:ok,
       {200, [],
        %{
          "object" => "subscriber_export",
          "subscriber" => Relay.Api.Subscribers.view(view),
          "deliveries" => Enum.map(kept, &(columns |> Enum.zip(&1) |> Map.new())),
          "truncated" => more != [],
          "exported_at" => Relay.Clock.utc_now()
        }}}
    end
  end

  defp subscriber(scope, external_id) do
    case Relay.Subscribers.fetch(scope, external_id) do
      {:ok, %{"_id" => <<_::128>>} = view} -> {:ok, view}
      _ -> {:error, Relay.Error.new(:subscriber_not_found, "no subscriber has this id")}
    end
  end

  defp audit(scope, id, digest, actor) do
    record = %{
      action: "subject.exported",
      target_type: "subscriber",
      target_id: Relay.ExternalId.encode("sub", id)
    }

    case Store.in_scope(scope, fn _status -> Store.audit(record, digest, actor) end) do
      {:ok, :appended} -> :ok
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp deliveries(scope, id) do
    case Relay.Delivery.subject_deliveries(scope, id, @max + 1) do
      {:ok, rows} -> {:ok, rows}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp unavailable, do: Relay.Error.new(:service_unavailable, "the export could not be read")
end
