defmodule Relay.Api.Imports do
  @moduledoc """
  Imports on the server API (OP-96, OP-55, OP-97). `POST /v1/imports?type=…&batch=…` takes an NDJSON upload of one of the types `suppressions`, `consents`, `subscribers`, `devices`, `templates` and `scheduled`. Outside any transaction its lines are counted and the upload is sealed under the tenant data key; the import row, its audit record (`import.requested`) and its job commit with the idempotency claim, and the answer is `202`. The order of OP-55 is enforced by the database function that records the request: a subscribers, devices or scheduled import of a batch is `409 import_order_violation` until the batch's suppressions and consents imports completed.

  The job (`Relay.Api.Imports.Job`) opens the upload, writes its lines through `Relay.Api.Imports.Runner`, records what each written line wrote for traceability, then completes the import with its report and clears the upload; an upload that cannot be opened fails as `content_unreadable`, and one the stores never accepted by the last attempt as `unavailable`. `GET /v1/imports/{id}` shows the state and the report.
  """

  alias Relay.Api.Imports.Job
  alias Relay.Api.Imports.Lines
  alias Relay.Api.Imports.Report
  alias Relay.Api.Imports.Runner
  alias Relay.Api.Imports.Store
  alias Relay.Api.Views

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @prefix "imp"
  @types ~w(suppressions consents subscribers devices templates scheduled)
  @batch ~r/\A[A-Za-z0-9._-]{1,64}\z/
  @max_lines Relay.Limits.fetch!(["import", "max_lines"])
  @record_chunk 500
  @provider_limit 100

  @doc "The external identifier prefix of an import."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  # OP-96
  @doc "Reads the `type` and `batch` query parameters of an import request."
  @spec query(map()) :: {:ok, %{type: String.t(), batch: String.t()}} | {:error, Relay.Error.t()}
  def query(params) do
    type = params["type"]
    batch = params["batch"]

    errors =
      [
        {type in @types, %{pointer: "/type", code: "unsupported_value", detail: "not a type"}},
        {is_binary(batch) and Regex.match?(@batch, batch),
         %{pointer: "/batch", code: "invalid_format", detail: "not a batch name"}}
      ]
      |> Enum.reject(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    if errors == [],
      do: {:ok, %{type: type, batch: batch}},
      else: {:error, Relay.Error.new(:validation_failed, "invalid query", %{errors: errors})}
  end

  # OP-96
  @doc "Prepares an import outside any transaction: the lines are counted against `import.max_lines` and the upload is sealed under the tenant data key."
  @spec prepare(Relay.Scope.t(), map(), binary()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def prepare(scope, %{type: type, batch: batch}, content) when is_binary(content) do
    lines = Lines.count(content)

    if lines > @max_lines do
      {:error,
       Relay.Error.new(:payload_too_large, "the upload has more than #{@max_lines} lines", %{
         limit: @max_lines,
         actual: lines,
         limit_name: "max_lines"
       })}
    else
      with {:ok, key_id, ct} <- seal(scope, content) do
        {:ok,
         %{
           id: Relay.Id.generate(),
           kind: type,
           batch: batch,
           line_count: lines,
           byte_size: byte_size(content),
           content_sha256: :crypto.hash(:sha256, content),
           content_ct: ct,
           content_key_id: key_id
         }}
      end
    end
  end

  defp seal(scope, content) do
    with {:ok, key_id} <- Relay.Tenancy.active_tenant_key(scope, :data),
         {:ok, ct} <- Relay.Tenancy.encrypt_field(field(scope, key_id), content) do
      {:ok, key_id, ct}
    else
      {:error, _error} -> {:error, unavailable()}
    end
  end

  defp field(scope, key_id) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: nil,
      retention_class: :recipient_profile,
      table: "imports",
      column: "content_ct",
      key_id: key_id
    }
  end

  # OP-96
  # OP-55 (2)
  @doc "Records a prepared import and queues its job inside the request's transaction; `202` with its view."
  @spec create(Relay.Scope.t(), map(), Relay.Actor.t()) :: answer()
  def create(scope, prepared, actor) do
    attrs = Map.put(prepared, :requested_by, actor.ref)

    case Store.request(attrs, digest(scope, prepared.id), actor) do
      :requested ->
        :ok = Store.insert_job!(job(scope, prepared.id))
        location = [{"location", "/v1/imports/" <> Views.id(@prefix, prepared.id)}]
        {:ok, {202, location, view(Store.get(prepared.id))}}

      :order_violation ->
        message = "import the batch's suppressions and consents first"
        {:error, Relay.Error.new(:import_order_violation, message)}
    end
  end

  # OP-96
  @doc "The job of an import."
  @spec job(Relay.Scope.t(), Relay.Id.t()) :: Ecto.Changeset.t()
  def job(scope, id) do
    scope
    |> Relay.Scope.to_job_args()
    |> Map.put("import_id", Relay.Id.to_string(id))
    |> Job.new()
  end

  # OP-96
  @doc "Reads an import in its own scoped transaction."
  @spec get(Relay.Scope.t(), Relay.Id.t()) :: answer()
  def get(scope, id) do
    case Store.in_scope(scope, fn _status -> Store.get(id) end) do
      {:ok, nil} -> {:error, not_found()}
      {:ok, row} -> {:ok, {200, [], view(row)}}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # OP-96
  @doc "The API view of an import row."
  @spec view(map()) :: map()
  def view(row) do
    %{
      "object" => "import",
      "id" => Views.id(@prefix, row["id"]),
      "type" => row["kind"],
      "batch" => row["batch"],
      "state" => row["state"],
      "failure" => row["failure"],
      "line_count" => row["line_count"],
      "byte_size" => row["byte_size"],
      "sha256" => Base.encode16(row["content_sha256"], case: :lower),
      "report" => row["report"],
      "completed_at" => row["completed_at"],
      "created_at" => row["created_at"]
    }
  end

  @doc "The error of an unknown import."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:import_not_found, "no import has this id")

  # OP-96
  # OP-55
  # OP-97
  @doc "Runs a pending import: opens its upload, writes its lines, records what they wrote and completes it with its report. `{:ok, :not_pending}` for an import that is no longer pending; `{:error, reason}` when a store was unavailable, so the job runs again."
  @spec run(Relay.Scope.t(), Relay.Id.t()) ::
          {:ok, :completed | :failed | :not_pending | :not_found} | {:error, term()}
  def run(scope, id) do
    case Store.in_scope(scope, fn _status -> Store.get(id) end) do
      {:ok, nil} -> {:ok, :not_found}
      {:ok, %{"state" => "pending"} = row} -> process(scope, row)
      {:ok, _done} -> {:ok, :not_pending}
      {:error, reason} -> {:error, reason}
    end
  end

  defp process(scope, row) do
    field = field(scope, row["content_key_id"])

    case Relay.Tenancy.decrypt_field(field, row["content_ct"]) do
      {:ok, content} ->
        lines = Lines.split(Relay.Redacted.expose(content))

        with {:ok, report} <- Runner.run(scope, row, lines),
             :ok <- records(scope, row["id"], Enum.reverse(report.records)) do
          complete(scope, row["id"], Report.document(report, providers(scope)))
        end

      {:error, _error} ->
        fail(scope, row["id"], "content_unreadable")
    end
  end

  defp records(scope, id, records) do
    records
    |> Enum.chunk_every(@record_chunk)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case Store.in_scope(scope, fn _status -> Store.record(id, chunk) end) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp complete(scope, id, document) do
    case Store.in_scope(scope, fn _status -> Store.complete(id, document) end) do
      {:ok, :completed} -> {:ok, :completed}
      {:ok, _other} -> {:ok, :not_pending}
      {:error, reason} -> {:error, reason}
    end
  end

  # OP-96
  @doc "Fails a pending import as `unavailable`, as its job does after its last attempt."
  @spec fail(Relay.Scope.t(), Relay.Id.t()) :: {:ok, atom()} | {:error, term()}
  def fail(scope, id), do: fail(scope, id, "unavailable")

  defp fail(scope, id, failure) do
    case Store.in_scope(scope, fn _status -> Store.fail(id, failure) end) do
      {:ok, :failed} -> {:ok, :failed}
      {:ok, _other} -> {:ok, :not_pending}
      {:error, reason} -> {:error, reason}
    end
  end

  # TN-58
  defp providers(scope) do
    case Relay.Channels.list_managed(scope, :account, nil, @provider_limit) do
      {:ok, rows} -> rows |> Enum.take(@provider_limit) |> Enum.map(&provider/1)
      {:error, _reason} -> []
    end
  end

  defp provider(account) do
    %{
      "channel" => account["channel"],
      "provider" => account["provider"],
      "in_installation" => account["in_installation"],
      "processing_countries" => account["processing_countries"],
      "transfer_basis" => account["transfer_basis"],
      "scc_notified_on" => date(account["scc_notified_on"])
    }
  end

  defp date(%Date{} = date), do: Date.to_iso8601(date)
  defp date(_other), do: nil

  defp digest(scope, id) do
    environment = Atom.to_string(scope.environment)
    parts = ["import", {:bytes, scope.tenant_id}, environment, Relay.Id.to_string(id)]
    :crypto.hash(:sha256, Relay.Canonical.encode!(parts))
  end

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
