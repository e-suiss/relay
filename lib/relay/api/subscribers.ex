defmodule Relay.Api.Subscribers do
  @moduledoc """
  The subscriber operations (API-66): create (`409 resource_conflict` when the external id exists), full replacement as upsert (`201` the first time), JSON Merge Patch under `If-Match`, reads with masked personal fields and the reachability summary, cursor lists, bulk upsert with per-row results, and deletion requests (`202`), carried out by crypto-shredding with no physical delete. Writes are prepared outside the transaction (keys and encryption) and written inside the request's idempotency transaction.
  """

  alias Relay.Api.Views

  @etag ~r/\A(?:W\/)?"?(\d{1,18})"?\z/

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}
  @type row :: {non_neg_integer(), map(), {:ok, map()} | {:error, Relay.Error.t()}}
  @type problem :: (Relay.Error.t() -> map())

  # T-59 (7)
  @doc "Reads an `If-Match` value as a version; `:missing` without one and `:invalid` for anything else."
  @spec if_match([String.t()]) :: {:ok, pos_integer()} | :missing | :invalid
  def if_match([]), do: :missing

  def if_match([value | _]) do
    case Regex.run(@etag, String.trim(value)) do
      [_, digits] -> {:ok, String.to_integer(digits)}
      nil -> :invalid
    end
  end

  @doc "The ETag header of a version."
  @spec etag(pos_integer()) :: {String.t(), String.t()}
  def etag(version), do: {"etag", ~s("#{version}")}

  # API-66
  @doc "Prepares a subscriber write outside any transaction; `mode` is `:create`, `:replace`, `:patch` or `:implicit`."
  @spec prepare(Relay.Scope.t(), String.t(), map(), atom()) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def prepare(scope, external_id, fields, mode) do
    input = %{external_id: external_id, fields: Map.drop(fields, ["external_id", "ref"])}

    case Relay.Subscribers.prepare(scope, input, mode, view: true) do
      {:ok, plan} -> {:ok, plan}
      {:error, %Relay.Error{code: :invalid_id}} -> {:error, not_found()}
      {:error, %Relay.Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # API-66
  @doc "Writes a prepared subscriber inside the request's transaction and answers with it."
  @spec write(Relay.Scope.t(), map(), pos_integer() | nil) :: answer()
  def write(scope, plan, expected_version) do
    with {:ok, {_result, status, view, version}} <- written(scope, plan, expected_version),
         do: {:ok, {status, [etag(version)], view}}
  end

  defp written(scope, plan, expected_version) do
    case Relay.Subscribers.upsert(plan, expected_version) do
      {result, id, version} when result in [:created, :updated, :unchanged] ->
        view = scope |> Relay.Subscribers.describe(Relay.Subscribers.row(id), plan) |> clean()
        {:ok, {result, status(result, plan.mode), view, version}}

      other ->
        refused(other, plan)
    end
  end

  defp status(:created, mode) when mode != :patch, do: 201
  defp status(_result, _mode), do: 200

  defp refused(outcome, plan) do
    case outcome do
      {:exists, _id, _version} when plan.mode == :create ->
        {:error, Relay.Error.new(:resource_conflict, "a subscriber with this external id exists")}

      {:recipient_not_found, _id, _version} ->
        {:error, not_found()}

      {:version_conflict, _id, _version} ->
        {:error, Relay.Error.new(:precondition_failed, "the subscriber changed; read it again")}

      {result, _id, _version} when result in [:is_agent, :deletion_pending] ->
        error = %{pointer: "/external_id", code: "not_allowed", detail: Atom.to_string(result)}

        {:error,
         Relay.Error.new(:recipient_invalid, "this external id cannot be written", %{
           errors: [error]
         })}

      {:tenant_inactive, _id, _version} ->
        {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}

      {_exists, _id, _version} ->
        {:error, unavailable()}
    end
  end

  # API-66
  # X-5
  @doc "Reads one subscriber by external id."
  @spec get(Relay.Scope.t(), String.t()) :: answer()
  def get(scope, external_id) do
    case Relay.Subscribers.fetch(scope, external_id) do
      {:ok, nil} -> {:error, not_found()}
      {:ok, view} -> {:ok, {200, [etag(view["version"])], clean(view)}}
      {:error, _reason} -> {:error, not_found()}
    end
  end

  # API-56
  # API-66
  @doc "Lists subscribers."
  @spec list(Relay.Scope.t(), Relay.Api.Pagination.page(), String.t()) :: answer()
  def list(scope, page, endpoint) do
    with {:ok, rows} <- Relay.Subscribers.list(scope, page.cursor, page.limit),
         {:ok, body} <-
           Relay.Api.Page.envelope(rows, page, scope, endpoint, &clean/1, fn row ->
             {row["_cursor_at"], row["_id"]}
           end) do
      {:ok, {200, [], body}}
    end
  end

  # API-66
  # OP-24
  @doc "Requests the deletion of a subscriber inside the request's transaction; answers `202` with the request."
  @spec delete(Relay.Scope.t(), map(), <<_::256>>, Relay.Actor.t()) :: answer()
  def delete(scope, plan, digest, actor) do
    case plan.existing do
      %{"id" => id, "kind" => "subscriber", "state" => state} when state != "deleted" ->
        case Relay.Subscribers.request_deletion(scope, id, digest, actor) do
          {:not_found, _request} -> {:error, not_found()}
          {_requested, request} -> {:ok, {202, [], deletion(request)}}
        end

      _other ->
        {:error, not_found()}
    end
  end

  defp deletion(request) do
    %{
      "object" => "subscriber_deletion",
      "id" => Views.id("sdr", request["id"]),
      "subscriber_id" => Views.id("sub", request["recipient_id"]),
      "status" => request["status"],
      "created_at" => request["created_at"],
      "completed_at" => request["completed_at"]
    }
  end

  # API-66
  # API-32
  @doc "Writes the rows of a bulk upsert inside the request's transaction, each in its own savepoint; `problem` renders a row's error."
  @spec bulk(Relay.Scope.t(), [row()], problem()) :: answer()
  def bulk(scope, rows, problem) do
    results = for row <- rows, do: bulk_row(scope, row, problem)

    rejected = Enum.count(results, &(&1["status"] == "rejected"))
    total = length(results)

    status =
      cond do
        rejected == 0 -> 200
        rejected == total -> 422
        true -> 207
      end

    {:ok,
     {status, [],
      %{
        "object" => "batch_result",
        "summary" => %{"total" => total, "accepted" => total - rejected, "rejected" => rejected},
        "results" => results
      }}}
  end

  defp bulk_row(scope, {index, row, prepared}, problem) do
    base = Views.put_unless_nil(%{"index" => index}, "ref", row["ref"])

    case bulk_write(scope, prepared) do
      {:ok, {result, _status, view, _version}} ->
        Map.merge(base, %{"status" => Atom.to_string(result), "subscriber" => view})

      {:error, error} ->
        Map.merge(base, %{"status" => "rejected", "error" => problem.(error)})
    end
  end

  defp bulk_write(scope, {:ok, plan}),
    do: Relay.Ingest.savepoint(fn -> written(scope, plan, nil) end)

  defp bulk_write(_scope, {:error, error}), do: {:error, error}

  defp clean(view), do: Map.drop(view, ["_id", "_cursor_at"])

  defp not_found, do: Relay.Error.new(:subscriber_not_found, "no subscriber has this id")

  defp unavailable do
    message = "the subscriber could not be written"
    Relay.Error.new(:service_unavailable, message, %{retry_after: 1})
  end
end
