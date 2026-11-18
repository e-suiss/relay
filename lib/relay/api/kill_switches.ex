defmodule Relay.Api.KillSwitches do
  @moduledoc """
  Kill switches on the server API (TN-41, TN-45, API-79 (6), X-47). An API client with the `kill_switch` scope may engage a campaign or workflow kill switch and replace it by a tighter one; stopping `security`, a record without TTL, releasing, relaxing, resuming and bulk cancelling need an operator session with step-up (`403 auth_operator_session_required`). The console's operator session acts with its role in the scope (`actor`: `%{kind: role, ref: subject, on_behalf_of_ref, access_record_ref}`): any tenant scope its rank reaches, with its step-up reference as the approval of a `security` stop, a record without TTL and a relaxation. Writes use the same records and audit entries as every other path (TN-45).
  """

  alias Relay.Api.Duration
  alias Relay.Api.Page
  alias Relay.Api.Views
  alias Relay.Tenancy.KillSwitch

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}
  @type written :: {:ok, {201, list(), map()}, non_neg_integer()} | {:error, Relay.Error.t()}
  @type actor_kind :: :api_client | :installation_operator | :tenant_admin | :tenant_operator
  @type actor :: %{
          required(:kind) => actor_kind(),
          required(:ref) => String.t(),
          optional(:on_behalf_of_ref) => String.t(),
          optional(:access_record_ref) => String.t() | nil
        }

  @classes ~w(security transactional operational social marketing system action_required)
  @approvals [
    :relax_approval_required,
    :security_approval_required,
    :no_ttl_approval_required,
    :approval_required
  ]
  @scopes %{
    "tenant" => :tenant,
    "subtenant" => :subtenant,
    "campaign" => :campaign,
    "workflow" => :workflow,
    "api_client" => :api_client,
    "sender" => :sender
  }

  @doc "The error an API client gets for what needs an operator session."
  @spec operator_session_required() :: Relay.Error.t()
  def operator_session_required,
    do:
      Relay.Error.new(
        :auth_operator_session_required,
        "this kill switch change needs an operator session with step-up"
      )

  # TN-36
  @doc "The API view of a kill switch record."
  @spec view(map()) :: map()
  def view(r) do
    %{
      "object" => "kill_switch",
      "id" => Views.id("ksw", r.id),
      "scope_kind" => Atom.to_string(r.scope_kind),
      "scope_ref" => r.scope_ref,
      "channel" => r.channel,
      "target_kind" => Atom.to_string(r.target_kind),
      "target_ref" => r.target_ref,
      "message_class" => r.message_class,
      "state" => Atom.to_string(r.state),
      "canary_percent" => r.canary_percent,
      "paused_until" => r.paused_until,
      "reason" => r.reason,
      "ticket_ref" => r.ticket_ref,
      "origin" => Atom.to_string(r.origin || :operator),
      "created_by" => r.created_by_ref,
      "expires_at" => r.expires_at,
      "supersedes_id" => Views.id("ksw", r.supersedes_id),
      "status" => Atom.to_string(r.status),
      "released_at" => r.released_at,
      "released_by" => r.released_by_ref,
      "release_reason" => r.release_reason,
      "created_at" => r.created_at
    }
  end

  # TN-41
  # API-79 (6)
  # X-47
  @doc "Builds the engage spec of a request, outside any transaction. An API client (`opts` empty) gets only campaign and workflow scopes, a TTL and no `security` stop; an operator session (`operator: true`) any tenant scope, with `approval` (its step-up reference) as the approval of a `security` stop and of a record without TTL (`no_ttl`). A workflow is named by its key, a sub-tenant by its `stn_` identifier; the tenant scope names nothing."
  @spec engage_spec(Relay.Scope.t(), map(), keyword()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def engage_spec(scope, body, opts \\ []) do
    kind = Map.fetch!(@scopes, body["scope_kind"])
    operator = Keyword.get(opts, :operator, false)
    approval = Keyword.get(opts, :approval)

    with :ok <- if(operator, do: :ok, else: client_may(kind, body)),
         {:ok, ref} <- scope_ref(scope, kind, body["scope_ref"]),
         {:ok, expires_at} <- expiry(body["ttl"], operator and body["no_ttl"] == true),
         {:ok, state} <- state(body) do
      {:ok,
       %{
         scope_kind: kind,
         scope: scope,
         scope_ref: ref,
         channel: body["channel"],
         target: target(body),
         message_class: class(body["message_class"]),
         security_approval: approval,
         state: state,
         reason: body["reason"],
         ticket: body["ticket_ref"],
         expires_at: expires_at,
         no_ttl_approval: approval
       }}
    end
  end

  defp client_may(kind, body) do
    if kind in [:campaign, :workflow] and body["message_class"] != "security" and
         body["no_ttl"] != true,
       do: :ok,
       else: {:error, operator_session_required()}
  end

  defp scope_ref(_scope, :tenant, _ref), do: {:ok, nil}
  defp scope_ref(_scope, _kind, nil), do: field_error("/scope_ref", "required", "name the scope")

  defp scope_ref(scope, :workflow, key) do
    case Relay.Workflow.resolve_published(scope, key) do
      {:ok, {:ok, workflow}} -> {:ok, workflow["workflow_id"]}
      {:ok, :not_published} -> workflow_id(scope, key)
      _ -> {:error, Relay.Error.new(:workflow_not_found, "no workflow has this key")}
    end
  end

  defp scope_ref(_scope, :campaign, ref), do: {:ok, ref}

  defp scope_ref(_scope, :subtenant, ref) do
    case Relay.ExternalId.decode(ref, ["stn"]) do
      {:ok, id} -> {:ok, id}
      {:error, _error} -> field_error("/scope_ref", "invalid_format", "a stn_ identifier")
    end
  end

  defp scope_ref(_scope, kind, ref) when kind in [:api_client, :sender], do: {:ok, ref}

  defp workflow_id(scope, key) do
    case Relay.Workflow.get(scope, key) do
      {:ok, %{"id" => id}} -> {:ok, id}
      _ -> {:error, Relay.Error.new(:workflow_not_found, "no workflow has this key")}
    end
  end

  # TN-41
  defp expiry(_ttl, true), do: {:ok, nil}
  defp expiry(nil, false), do: field_error("/ttl", "required", "a kill switch needs a TTL")

  defp expiry(ttl, false) do
    case Duration.to_ms(ttl) do
      {:ok, ms} when ms > 0 -> {:ok, DateTime.add(Relay.Clock.utc_now(), ms, :millisecond)}
      _ -> field_error("/ttl", "invalid_format", "weeks, days, hours, minutes or seconds")
    end
  end

  defp state(%{"state" => "canary", "canary_percent" => p}) when is_integer(p),
    do: {:ok, {:canary, p}}

  defp state(%{"state" => "canary"}),
    do: field_error("/canary_percent", "required", "a canary needs its percent")

  defp state(%{"state" => "paused_until", "paused_until" => text}) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> {:ok, {:paused_until, at}}
      _ -> field_error("/paused_until", "invalid_format", "RFC 3339 time")
    end
  end

  defp state(%{"state" => "paused_until"}),
    do: field_error("/paused_until", "required", "a pause needs its end")

  defp state(_body), do: {:ok, :off}

  defp target(%{"target_kind" => "provider_account", "target_ref" => ref}),
    do: {:provider_account, ref}

  defp target(%{"target_kind" => "template", "target_ref" => ref}), do: {:template, ref}
  defp target(_body), do: :all

  defp class(class) when class in @classes, do: class
  defp class(_class), do: nil

  # TN-41
  # TN-45
  # X-47
  @doc "Engages a prepared kill switch inside the request's transaction; `201` with the record. `actor` is an API client's reference or an operator `actor()`."
  @spec engage(map(), String.t() | actor()) :: written()
  def engage(spec, client_ref) when is_binary(client_ref),
    do: engage(spec, %{kind: :api_client, ref: client_ref})

  def engage(spec, %{kind: _, ref: actor_ref} = actor) do
    case KillSwitch.engage_here(spec, actor) do
      {:ok, %{id: id, generation: generation}} ->
        {target_kind, target_ref} =
          case spec.target do
            :all -> {:all, nil}
            {kind, ref} -> {kind, ref}
          end

        record =
          spec
          |> state_fields()
          |> Map.merge(%{
            id: decode(id),
            scope_kind: spec.scope_kind,
            scope_ref: ref_text(spec.scope_ref),
            channel: spec.channel,
            target_kind: target_kind,
            target_ref: target_ref,
            message_class: spec.message_class,
            reason: spec.reason,
            ticket_ref: spec.ticket,
            created_by_ref: actor_ref,
            expires_at: spec.expires_at,
            supersedes_id: nil
          })

        {:ok, {201, [], view(fresh(record))}, generation}

      {:error, reason} ->
        {:error, engage_error(reason, actor)}
    end
  end

  defp state_fields(%{state: :off}), do: %{state: :off, canary_percent: nil, paused_until: nil}

  defp state_fields(%{state: {:canary, percent}}),
    do: %{state: :canary, canary_percent: percent, paused_until: nil}

  defp state_fields(%{state: {:paused_until, at}}),
    do: %{state: :paused_until, canary_percent: nil, paused_until: at}

  defp fresh(record) do
    Map.merge(record, %{
      origin: :operator,
      status: :active,
      released_at: nil,
      released_by_ref: nil,
      release_reason: nil,
      created_at: Relay.Clock.utc_now()
    })
  end

  defp ref_text(<<_::128>> = id), do: Relay.Id.to_string(id)
  defp ref_text(ref), do: ref

  defp decode(id) do
    {:ok, uuid} = Relay.ExternalId.decode(id, ["ksw"])
    uuid
  end

  # TN-22
  # X-47
  @doc "Replaces a kill switch read before, inside the request's transaction; only a tighter state is accepted from an API client (`actor` its reference). An operator `actor()` may relax and drop the TTL with `approval`, its step-up reference."
  @spec replace(map(), map(), String.t() | actor(), String.t() | nil) :: written()
  def replace(record, body, actor, approval \\ nil)

  def replace(record, body, client_ref, approval) when is_binary(client_ref),
    do: replace(record, body, %{kind: :api_client, ref: client_ref}, approval)

  def replace(record, body, %{kind: kind, ref: actor_ref} = actor, approval) do
    operator = kind != :api_client

    with :ok <- no_ttl_allowed(operator, body),
         {:ok, state} <- state(body),
         {:ok, expires_at} <- expiry(body["ttl"], operator and body["no_ttl"] == true) do
      change = %{
        state: state,
        reason: body["reason"],
        expires_at: expires_at,
        no_ttl_approval: if(is_nil(expires_at), do: approval),
        relax_approval: approval
      }

      case KillSwitch.replace_here(record, change, actor) do
        {:ok, %{id: id, generation: generation}} ->
          new =
            record
            |> Map.merge(state_fields(%{state: state}))
            |> Map.merge(%{
              id: decode(id),
              reason: body["reason"],
              created_by_ref: actor_ref,
              expires_at: expires_at,
              supersedes_id: record.id
            })

          {:ok, {201, [], view(fresh(new))}, generation}

        {:error, reason} ->
          {:error, engage_error(reason, actor)}
      end
    end
  end

  defp no_ttl_allowed(false, %{"no_ttl" => true}), do: {:error, operator_session_required()}
  defp no_ttl_allowed(_operator, _body), do: :ok

  # TN-22
  # TN-40
  # X-47
  @doc "Releases a kill switch read before for an operator `actor()` with `approval`, its step-up reference; the command runs its own transaction. `200` with the released record; paused deliveries stay paused."
  @spec release(map(), String.t(), actor(), String.t() | nil) :: answer()
  def release(record, reason, actor, approval) do
    change = %{reason: reason, relax_approval: approval}

    case KillSwitch.release(record.id, change, actor) do
      {:ok, _result} ->
        released =
          Map.merge(record, %{
            status: :released,
            released_at: Relay.Clock.utc_now(),
            released_by_ref: actor.ref,
            release_reason: reason
          })

        {:ok, {200, [], view(released)}}

      {:error, code} ->
        {:error, engage_error(code, actor)}
    end
  end

  # TN-40
  # TN-22
  # X-47
  @doc "Resumes the deliveries a released kill switch paused, for an operator `actor()` with `approval`; each passes the policy lattice again. `200` with the number of deliveries the lattice sent, deferred, cancelled or expired."
  @spec resume(map(), String.t(), actor(), String.t() | nil) :: answer()
  def resume(record, reason, actor, approval) do
    change = %{
      reason: reason,
      relax_approval: approval,
      scope_kind: record.scope_kind,
      job: &Relay.Delivery.send_job/2
    }

    case KillSwitch.resume(record.id, change, actor) do
      {:ok, totals} ->
        affected = totals |> Map.values() |> Enum.sum()
        {:ok, {200, [], action_view(record, "resume", affected)}}

      {:error, :policy_lattice_unavailable} ->
        {:error, Relay.Error.new(:service_unavailable, "the policy lattice cannot be read")}

      {:error, code} ->
        {:error, engage_error(code, actor)}
    end
  end

  # TN-47
  # X-47
  @doc "Cancels every delivery a kill switch paused, for an operator `actor()`; one `killswitch.bulk_cancelled` audit record in the record's scope. `200` with the number cancelled."
  @spec cancel_paused(map(), String.t(), actor()) :: answer()
  def cancel_paused(record, reason, actor) do
    scope = Relay.Scope.new!(record.tenant_id, record.environment)
    change = %{reason: reason, scope_kind: record.scope_kind, scope: scope}

    case KillSwitch.bulk_cancel(record.id, change, actor) do
      {:ok, %{cancelled: cancelled}} ->
        {:ok, {200, [], action_view(record, "bulk_cancel", cancelled)}}

      {:error, code} ->
        {:error, engage_error(code, actor)}
    end
  end

  defp action_view(record, action, affected) do
    %{
      "object" => "kill_switch_action",
      "kill_switch_id" => Views.id("ksw", record.id),
      "action" => action,
      "affected" => affected,
      "has_more" => false
    }
  end

  defp engage_error(reason, %{kind: :api_client}) when reason in [:forbidden | @approvals],
    do: operator_session_required()

  defp engage_error(reason, _operator) when reason in @approvals,
    do: Relay.Error.new(:auth_step_up_required, "this kill switch change needs a fresh step-up")

  defp engage_error(:forbidden, _operator),
    do: Relay.Error.new(:auth_insufficient_role, "the operator's role does not reach the scope")

  defp engage_error(reason, _actor), do: engage_error(reason)

  defp engage_error(:scope_not_found),
    do: Relay.Error.new(:workflow_not_found, "no workflow has this key")

  defp engage_error(:not_found), do: not_found()
  defp engage_error(:already_released), do: Relay.Error.new(:resource_conflict, "released")

  defp engage_error(reason),
    do:
      Relay.Error.new(:validation_failed, "the kill switch is invalid", %{
        errors: [%{pointer: "", code: "invalid_format", detail: Atom.to_string(reason)}]
      })

  # TN-41
  @doc "Reads a kill switch of `scope` (or a platform record that applies to it), outside any transaction."
  @spec fetch(Relay.Scope.t(), String.t()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def fetch(scope, id) do
    case KillSwitch.record(id) do
      {:ok, record} ->
        if record.scope_kind == :platform or
             (record.tenant_id == scope.tenant_id and record.environment == scope.environment),
           do: {:ok, record},
           else: {:error, not_found()}

      {:error, _reason} ->
        {:error, not_found()}
    end
  end

  # TN-40
  # TN-47
  @doc "Reads a kill switch of `scope` (or a platform record that applies to it), in force or released, outside any transaction; resuming and bulk cancelling act on released records."
  @spec fetch_any(Relay.Scope.t(), String.t()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def fetch_any(scope, id) do
    with {:ok, <<n::128>> = uuid} <- Relay.ExternalId.decode(id, ["ksw"]),
         opts = [include_released: true, after: <<n - 1::128>>, limit: 1],
         {:ok, [%{id: ^uuid} = record | _]} <- KillSwitch.list(scope, opts) do
      {:ok, record}
    else
      _ -> {:error, not_found()}
    end
  end

  # TN-41
  @doc "Lists the kill switches that apply to `scope`."
  @spec list(Relay.Scope.t(), boolean(), Relay.Api.Pagination.page(), String.t()) :: answer()
  def list(scope, include_released, page, endpoint) do
    opts = [include_released: include_released, limit: page.limit + 1]
    opts = if page.cursor, do: Keyword.put(opts, :after, page.cursor.id), else: opts

    case KillSwitch.list(scope, opts) do
      {:ok, records} ->
        page = %{page | cursor: page.cursor && %{page.cursor | direction: :after}}

        position = &{&1.created_at, &1.id}
        envelope = Page.envelope(records, page, scope, endpoint, &view/1, position)
        with {:ok, body} <- envelope, do: {:ok, {200, [], body}}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "The error of an unknown kill switch."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:kill_switch_not_found, "no such kill switch")

  defp field_error(pointer, code, detail) do
    {:error,
     Relay.Error.new(:validation_failed, "the kill switch request is invalid", %{
       errors: [%{pointer: pointer, code: code, detail: detail}]
     })}
  end
end
