defmodule Relay.TenantLifecycle.Closure do
  @moduledoc """
  Closing a tenant in two steps, both installation operator actions with step-up (OP-86, OP-26).

  Step one records the closure in the tenant's `live` environment, sets the tenant `closed` so that every entry point refuses new work, and queues the full export in the same transaction, all audited as `tenant.closed`. The export job (`Relay.TenantLifecycle.ClosureJob`) writes every export kind of both environments, page by page, as JSON lines and CSV files to the installation's object store (`Relay.TenantLifecycle.ExportStore`) under the closure's own prefix, then a `manifest.json` with each file's environment, kind, format, row count, size and SHA-256; when it is written the closure is `export_ready` (`tenant.export_ready`) and its files are offered through signed links that expire after a day. The formats are a list: Parquet joins it when the archive writer is available.

  Step two crypto-shreds the tenant (`Relay.Keys.Erasure.shred_tenant/2`) in both environments: no earlier than 30 days after the export was ready, or once the tenant's explicit confirmation is recorded (`tenant.closure_confirmed`). It starts with `tenant.shred_started`, each environment writes `tenant.shredded`, and a step that fails is run again by repeating the request. Records under a legal retention obligation stay readable for their period.
  """

  alias Relay.Actor
  alias Relay.Error
  alias Relay.Scope
  alias Relay.TenantLifecycle.ClosureJob
  alias Relay.TenantLifecycle.ExportStore
  alias Relay.TenantLifecycle.Store

  @formats ~w(jsonl csv)
  @environments [:live, :test]
  @delivery_page 5_000
  @subscriber_page 500
  @link_ttl_s 86_400
  @subscriber_columns ~w(id external_id locale timezone legal_type country state created_at
                         updated_at)
  @system %Actor{
    kind: :system,
    ref: "relay:tenant_closure",
    on_behalf_of_ref: "relay:tenant_closure"
  }
  @content_types %{"jsonl" => "application/x-ndjson", "csv" => "text/csv; charset=utf-8"}

  @type digest_fun ::
          (Scope.t(), String.t(), String.t(), String.t(), String.t() | nil -> <<_::256>>)

  # OP-86
  @doc "The actor of the export job's audit records."
  @spec system_actor() :: Actor.t()
  def system_actor, do: @system

  # OP-86
  @doc "The export formats this installation writes; Parquet is added when the archive writer is available."
  @spec formats() :: [String.t(), ...]
  def formats, do: @formats

  # OP-86
  @doc "The export kinds of each environment."
  @spec kinds() :: [String.t(), ...]
  def kinds, do: ["subscribers" | Relay.Delivery.export_kinds()]

  # OP-86
  # OP-26
  # TN-10
  @doc "Requests the closure of a tenant: records it, closes the tenant and queues its export, in one transaction. Returns the closure."
  @spec request(Relay.Id.t(), map(), Actor.t(), String.t() | nil, digest_fun()) ::
          {:ok, map()} | {:error, Error.t()}
  def request(<<_::128>> = tenant_id, attrs, %Actor{} = actor, step_up_ref, digest) do
    live = Scope.new!(tenant_id, :live)
    id = Relay.Id.generate()

    with {:ok, formats} <- requested_formats(Map.get(attrs, :formats)),
         {:ok, reason} <- reason(Map.get(attrs, :reason)) do
      record = %{
        id: id,
        reason: reason,
        formats: formats,
        export_prefix: prefix(tenant_id, id),
        step_up_ref: step_up_ref
      }

      record_digest =
        digest.(live, "tenant.closed", "tenant", Relay.Id.to_string(tenant_id), reason)

      live
      |> Store.in_scope(fn _status -> requested(live, record, record_digest, actor) end)
      |> outcome()
    end
  end

  defp requested(live, record, digest, actor) do
    case Store.request(record, digest, actor) do
      {:requested, id} ->
        args = live |> Scope.to_job_args() |> Map.put("closure_id", Relay.Id.to_string(id))

        case Oban.insert(ClosureJob.new(args)) do
          {:ok, _job} -> {:ok, Store.get()}
          {:error, reason} -> Store.rollback({:job_not_queued, reason})
        end

      {:exists, _id} ->
        {:error, Error.new(:resource_conflict, "the tenant already has a closure")}

      {:not_allowed, _id} ->
        {:error, Error.new(:resource_conflict, "the installation tenant cannot be closed")}
    end
  end

  defp requested_formats(nil), do: {:ok, @formats}

  defp requested_formats([_ | _] = formats) do
    if Enum.all?(formats, &(&1 in @formats)) do
      {:ok, Enum.uniq(formats)}
    else
      {:error, field("/formats", "unsupported_value", "a format this installation writes")}
    end
  end

  defp requested_formats(_formats),
    do: {:error, field("/formats", "invalid_format", "a non-empty list of formats")}

  defp reason(reason) when is_binary(reason) and reason != "" do
    if String.length(reason) <= 2000,
      do: {:ok, reason},
      else: {:error, field("/reason", "too_long", "at most 2000 characters")}
  end

  defp reason(_reason), do: {:error, field("/reason", "required", "a reason is required")}

  defp prefix(tenant_id, id),
    do: "tenants/#{Relay.Id.to_string(tenant_id)}/closures/#{Relay.Id.to_string(id)}/"

  # OP-86
  @doc "Reads the closure of a tenant with a signed download link for each exported file once the export is ready."
  @spec show(Relay.Id.t()) :: {:ok, map()} | {:error, Error.t()}
  def show(<<_::128>> = tenant_id) do
    with {:ok, closure} <- read(tenant_id), do: links(closure)
  end

  defp links(%{"state" => state, "export_manifest" => %{"files" => files}} = closure)
       when state in ["export_ready", "shredding"] do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case ExportStore.url(closure["export_prefix"] <> file["key"], @link_ttl_s) do
        {:ok, url} -> {:cont, {:ok, [Map.put(file, "url", url) | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, linked} ->
        expires = DateTime.add(Relay.Clock.utc_now(), @link_ttl_s, :second)
        files = Enum.reverse(linked)
        {:ok, Map.merge(closure, %{"files" => files, "links_expire_at" => expires})}

      {:error, error} ->
        {:error, error}
    end
  end

  defp links(closure), do: {:ok, Map.merge(closure, %{"files" => [], "links_expire_at" => nil})}

  # OP-86
  @doc "Records the tenant's explicit confirmation that its keys may be destroyed before the 30 days after the export are over; `confirmation_ref` names the evidence of the confirmation."
  @spec confirm(Relay.Id.t(), String.t(), Actor.t(), digest_fun()) ::
          {:ok, map()} | {:error, Error.t()}
  def confirm(<<_::128>> = tenant_id, confirmation_ref, %Actor{} = actor, digest) do
    live = Scope.new!(tenant_id, :live)

    with :ok <- confirmation(confirmation_ref),
         {:ok, closure} <- read(tenant_id) do
      record_digest =
        digest.(
          live,
          "tenant.closure_confirmed",
          "tenant_closure",
          Relay.Id.to_string(closure["id"]),
          confirmation_ref
        )

      live
      |> Store.in_scope(fn _status ->
        confirmed(Store.confirm(closure["id"], confirmation_ref, record_digest, actor))
      end)
      |> outcome()
    end
  end

  defp confirmed(result) when result in [:confirmed, :already_confirmed], do: {:ok, Store.get()}
  defp confirmed(:not_ready), do: {:error, conflict("the export is not ready")}
  defp confirmed(:not_found), do: {:error, not_found()}

  defp confirmation(ref) when is_binary(ref) and ref != "" do
    if String.length(ref) <= 256,
      do: :ok,
      else: {:error, field("/confirmation_ref", "too_long", "at most 256 characters")}
  end

  defp confirmation(_ref),
    do: {:error, field("/confirmation_ref", "required", "the evidence of the confirmation")}

  # OP-86
  # OP-26
  @doc "Destroys the keys of a closed tenant once its export has been ready for 30 days or its confirmation is recorded; returns the closure with the counts of destroyed and restricted keys."
  @spec shred(Relay.Id.t(), Actor.t(), String.t() | nil, digest_fun()) ::
          {:ok, map()} | {:error, Error.t()}
  def shred(<<_::128>> = tenant_id, %Actor{} = actor, step_up_ref, digest) do
    live = Scope.new!(tenant_id, :live)

    with {:ok, closure} <- read(tenant_id),
         id = closure["id"],
         :ok <- begin(live, id, step_up_ref, actor, digest),
         {:ok, counts} <- shred_environments(tenant_id, actor),
         {:ok, _finished} <- finish(live, id),
         {:ok, closure} <- read(tenant_id) do
      {:ok, Map.put(closure, "shredded", counts)}
    end
  end

  defp begin(live, id, step_up_ref, actor, digest) do
    record_digest =
      digest.(live, "tenant.shred_started", "tenant_closure", Relay.Id.to_string(id), nil)

    live
    |> Store.in_scope(fn _status ->
      case Store.shred_begin(id, step_up_ref, record_digest, actor) do
        result when result in [:started, :already_started] -> {:ok, result}
        :not_due -> {:error, conflict("the keys are destroyed 30 days after the export")}
        :not_ready -> {:error, conflict("the export is not ready")}
        :not_found -> {:error, not_found()}
      end
    end)
    |> outcome()
    |> case do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp finish(live, id),
    do: outcome(Store.in_scope(live, fn _status -> {:ok, Store.shred_finish(id)} end))

  defp shred_environments(tenant_id, actor) do
    zero = %{keys: 0, deks: 0, restricted: 0}

    Enum.reduce_while(Enum.reverse(@environments), {:ok, zero}, fn environment, {:ok, total} ->
      case Relay.Keys.Erasure.shred_tenant(Scope.new!(tenant_id, environment), actor) do
        {:ok, :shredded, counts} ->
          {:cont, {:ok, Map.merge(total, counts, fn _key, a, b -> a + b end)}}

        {:ok, :held, _counts} ->
          {:halt, {:error, conflict("a legal hold is active on the tenant")}}

        {:ok, :not_allowed, _counts} ->
          {:halt, {:error, conflict("the tenant is not closed")}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  # OP-86
  # OP-26
  @doc "Writes the full export of a closure and marks it ready; a closure that is not exporting is left alone. Run by `Relay.TenantLifecycle.ClosureJob`."
  @spec run_export(Relay.Id.t(), Relay.Id.t(), digest_fun()) ::
          {:ok, :ready | :not_exporting} | {:error, term()}
  def run_export(<<_::128>> = tenant_id, <<_::128>> = closure_id, digest) do
    live = Scope.new!(tenant_id, :live)

    case read(tenant_id) do
      {:ok, %{"id" => ^closure_id, "state" => "exporting"} = closure} ->
        with {:ok, manifest} <- export(tenant_id, closure) do
          ready(live, closure_id, manifest, digest)
        end

      {:ok, _closure} ->
        {:ok, :not_exporting}

      {:error, error} ->
        {:error, error}
    end
  end

  defp ready(live, closure_id, manifest, digest) do
    record_digest =
      digest.(
        live,
        "tenant.export_ready",
        "tenant_closure",
        Relay.Id.to_string(closure_id),
        nil
      )

    live
    |> Store.in_scope(fn _status ->
      case Store.export_ready(closure_id, manifest, record_digest, @system) do
        :ready -> {:ok, :ready}
        _other -> {:ok, :not_exporting}
      end
    end)
    |> outcome()
  end

  defp export(tenant_id, closure) do
    prefix = closure["export_prefix"]
    formats = closure["formats"]

    entries =
      for environment <- @environments, kind <- kinds(), reduce: {:ok, []} do
        {:ok, acc} ->
          scope = Scope.new!(tenant_id, environment)

          case export_kind(scope, kind, formats, prefix) do
            {:ok, files} -> {:ok, acc ++ files}
            {:error, error} -> {:error, error}
          end

        error ->
          error
      end

    with {:ok, files} <- entries do
      manifest = %{
        "version" => 1,
        "tenant" => Relay.ExternalId.encode("ten", tenant_id),
        "closure" => Relay.Id.to_string(closure["id"]),
        "formats" => formats,
        "written_at" => DateTime.to_iso8601(Relay.Clock.utc_now()),
        "files" => files
      }

      body = Jason.encode!(manifest)

      with :ok <- ExportStore.put(prefix <> "manifest.json", body, "application/json"),
           do: {:ok, manifest}
    end
  end

  defp export_kind(scope, kind, formats, prefix) do
    part = %{scope: scope, kind: kind, columns: columns(kind), formats: formats, prefix: prefix}
    export_pages(part, nil, 1, [])
  end

  defp export_pages(part, cursor, number, acc) do
    with {:ok, {rows, next}} <- page(part.scope, part.kind, cursor),
         do: export_rows(part, rows, next, number, acc)
  end

  defp export_rows(_part, [], _next, number, acc) when number > 1, do: {:ok, acc}

  defp export_rows(part, rows, next, number, acc) do
    with {:ok, files} <- write_part(part, rows, number),
         do: continue(part, next, number, acc ++ files)
  end

  defp continue(_part, nil, _number, acc), do: {:ok, acc}
  defp continue(part, next, number, acc), do: export_pages(part, next, number + 1, acc)

  defp write_part(part, rows, number) do
    environment = Relay.Environment.dump(part.scope.environment)
    kind = part.kind
    name = "#{environment}/#{kind}/part-#{String.pad_leading(Integer.to_string(number), 5, "0")}"

    Enum.reduce_while(part.formats, {:ok, []}, fn format, {:ok, acc} ->
      body = IO.iodata_to_binary(encode(format, part.columns, rows))
      key = name <> "." <> format

      case ExportStore.put(part.prefix <> key, body, Map.fetch!(@content_types, format)) do
        :ok ->
          entry = %{
            "environment" => environment,
            "kind" => kind,
            "format" => format,
            "key" => key,
            "rows" => length(rows),
            "bytes" => byte_size(body),
            "sha256" => Base.encode16(:crypto.hash(:sha256, body), case: :lower)
          }

          {:cont, {:ok, [entry | acc]}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  # OP-86
  @doc "One file of rows in an export format: JSON lines with one object per row, or CSV with a header row."
  @spec encode(String.t(), [String.t()], [[term()]]) :: iodata()
  def encode("jsonl", columns, rows),
    do: Enum.map(rows, &[Jason.encode_to_iodata!(columns |> Enum.zip(&1) |> Map.new()), "\n"])

  def encode("csv", columns, rows) do
    [Relay.Delivery.export_csv_line(columns) | Enum.map(rows, &Relay.Delivery.export_csv_line/1)]
  end

  defp columns("subscribers"), do: @subscriber_columns
  defp columns(kind), do: Relay.Delivery.export_columns(kind)

  defp page(scope, "subscribers", cursor) do
    case Relay.Subscribers.list(scope, cursor, @subscriber_page) do
      {:ok, found} ->
        {rows, more} = Enum.split(found, @subscriber_page)
        next = if more == [], do: nil, else: subscriber_cursor(List.last(rows))
        {:ok, {Enum.map(rows, fn row -> Enum.map(@subscriber_columns, &row[&1]) end), next}}

      {:error, _reason} ->
        {:error, Error.new(:service_unavailable, "subscribers could not be read")}
    end
  end

  defp page(scope, kind, cursor) do
    case Relay.Delivery.export_history_page(scope, kind, cursor, @delivery_page) do
      {:ok, {rows, next}} -> {:ok, {rows, next}}
      {:error, _reason} -> {:error, Error.new(:service_unavailable, "rows could not be read")}
    end
  end

  defp subscriber_cursor(row) do
    %{
      direction: :after,
      sort_ts_us: DateTime.to_unix(row["_cursor_at"], :microsecond),
      id: row["_id"]
    }
  end

  defp read(tenant_id) do
    case Store.in_scope(Scope.new!(tenant_id, :live), fn _status -> Store.get() end) do
      {:ok, nil} -> {:error, not_found()}
      {:ok, closure} -> {:ok, closure}
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Error.new(:database_error, "closure read failed")}
    end
  end

  defp outcome({:ok, {:ok, value}}), do: {:ok, value}
  defp outcome({:ok, {:error, %Error{} = error}}), do: {:error, error}
  defp outcome({:error, %Error{} = error}), do: {:error, error}

  defp outcome({:error, _reason}),
    do: {:error, Error.new(:database_error, "closure write failed")}

  defp not_found, do: Error.new(:tenant_closure_not_found, "the tenant has no closure")
  defp conflict(message), do: Error.new(:resource_conflict, message)

  defp field(pointer, code, detail) do
    Error.new(:validation_failed, detail, %{
      errors: [%{pointer: pointer, code: code, detail: detail}]
    })
  end
end
