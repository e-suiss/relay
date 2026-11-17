defmodule Relay.Access.IysReport do
  @moduledoc """
  The report of an Access İYS consent record to Access (E-109, E-21): once İYS registered the record or Relay can no longer register it, Relay posts `{tenant, environment, record, status, reason?, at}` to `POST {api_base}/relay/v1/iys-status` with its RFC 7523 client assertion (`Relay.Access.Client.product_post/3`). `tenant` is the `tnt_` identifier of the tenant whose brand wrote the consent, `environment` the Access environment and `record` the CloudEvents `id` of the `relay.message.iys_consent.v1` message; `status` is `recorded` or `failed`, `reason` a short lower-case code given only with `failed`, and `at` the time in Unix milliseconds.

  The job is queued inside the transaction that settles the upload, or that refuses the record before an upload exists, and carries only identifiers and codes (T-15); the request is made outside any transaction. A `2xx` answer ends it, as does `404` (Access holds no such record) and a malformed-report `400` or `413`; any other answer and a transport failure are tried again. `api_base` is the configured `api_base` of `Relay.Access`, or the origin of the linked issuer.
  """

  use Relay.Worker, queue: :l1, priority: 3, max_attempts: 20, timeout: 30_000

  require Logger

  @path "/relay/v1/iys-status"
  @reason ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  # E-109
  # T-15
  @doc "Queues the report of one record inside the caller's scoped transaction: `report` is `%{\"upload_id\" => id}` for a settled upload, or `record`, `access_environment`, `status`, `reason` and `at` (Unix milliseconds) for a record that opened no upload."
  @spec enqueue(Relay.Scope.t(), map()) :: :ok | {:error, term()}
  def enqueue(%Relay.Scope{} = scope, %{} = report) do
    attrs = %{
      id: Relay.Id.generate(),
      lane: Relay.Platform.lane(:transactional),
      worker: __MODULE__,
      args: Map.merge(report, Relay.Scope.to_job_args(scope)),
      ref_kind: "iys_access_report",
      ref_id: ref_id(report),
      priority: 3
    }

    case Relay.Platform.enqueue_job(attrs) do
      {:ok, _queued} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp ref_id(%{"upload_id" => text}) do
    case Relay.Id.parse(text) do
      {:ok, id} -> id
      {:error, _invalid} -> Relay.Id.generate()
    end
  end

  defp ref_id(_report), do: Relay.Id.generate()

  # E-109
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, report} <- report(scope, args),
         {:ok, tenant} <- access_tenant(scope) do
      post(Map.put(report, "tenant", tenant))
    end
  end

  defp report(scope, %{"upload_id" => text}) do
    case Relay.Id.parse(text) do
      {:ok, id} -> upload_report(Relay.Iys.access_report(scope, id))
      {:error, _invalid} -> {:cancel, "malformed upload"}
    end
  end

  defp report(_scope, %{"record" => record, "access_environment" => environment} = args) do
    {:ok,
     compact(%{
       "environment" => environment,
       "record" => record,
       "status" => args["status"],
       "reason" => reason(args["status"], args["reason"]),
       "at" => args["at"]
     })}
  end

  defp report(_scope, _args), do: {:cancel, "malformed report"}

  defp upload_report({:ok, %{} = upload}), do: {:ok, from_upload(upload)}
  defp upload_report({:ok, nil}), do: {:cancel, "no access record"}
  defp upload_report({:error, reason}), do: {:error, reason}

  # E-109
  @doc "The report of a settled upload: `recorded` when İYS holds the record (`confirmed`, or a refusal İYS had nothing to refuse for), `failed` with its error code otherwise."
  @spec from_upload(map()) :: map()
  def from_upload(%{} = upload) do
    status = status(upload["state"])
    code = upload["error_code"] || upload["state"]

    compact(%{
      "environment" => uuid(upload["access_environment"]),
      "record" => uuid(upload["access_record"]),
      "status" => status,
      "reason" => reason(status, code),
      "at" => at(upload["settled_at"])
    })
  end

  defp status("confirmed"), do: "recorded"
  defp status("skipped"), do: "recorded"
  defp status(_failed_or_expired), do: "failed"

  defp reason("failed", code) when is_binary(code) do
    normal = code |> String.downcase() |> String.replace(~r/[^a-z0-9_-]/, "_")
    normal = if normal =~ ~r/\A[a-z]/, do: normal, else: "e" <> normal
    candidate = String.slice(normal, 0, 64)
    if Regex.match?(@reason, candidate), do: candidate, else: "failed"
  end

  defp reason("failed", _none), do: "failed"
  defp reason(_recorded, _code), do: nil

  defp at(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)
  defp at(_none), do: DateTime.to_unix(Relay.Clock.utc_now(), :millisecond)

  defp uuid(<<_::128>> = id), do: Ecto.UUID.cast!(id)
  defp uuid(text) when is_binary(text), do: text

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp access_tenant(scope) do
    case Relay.Tenancy.tenant(scope) do
      {:ok, %{"access_tenant_id" => tenant}} when is_binary(tenant) -> {:ok, tenant}
      {:ok, _other} -> {:cancel, "the tenant has no Access tenant"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post(body) do
    case Relay.Access.api_base() do
      base when is_binary(base) ->
        answer(Relay.Access.Client.product_post(base <> @path, body))

      _unset ->
        {:error, :access_not_configured}
    end
  end

  defp answer({:ok, status}) when status in 200..299, do: :ok

  defp answer({:ok, 404}) do
    Logger.warning("Access holds no İYS consent record for a report", event: "access.iys_report")
    {:cancel, "record not found"}
  end

  defp answer({:ok, status}) when status in [400, 413], do: {:cancel, "report refused"}
  defp answer({:ok, status}), do: {:error, "Access answered #{status}"}
  defp answer({:error, %Relay.Error{code: code}}), do: {:error, code}
end
