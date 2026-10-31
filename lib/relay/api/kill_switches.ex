defmodule Relay.Api.KillSwitches do
  @moduledoc """
  Kill switches on the server API (TN-41, TN-45, API-79 (6)). An API client with the `kill_switch` scope may engage a campaign or workflow kill switch and replace it by a tighter one; stopping `security`, a record without TTL, releasing, relaxing, resuming and bulk cancelling need an operator session with step-up (`403 auth_operator_session_required`). Writes use the same records and audit entries as every other path (TN-45).
  """

  alias Relay.Api.Duration
  alias Relay.Api.Page
  alias Relay.Api.Views
  alias Relay.Tenancy.KillSwitch

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}
  @type written :: {:ok, {201, list(), map()}, non_neg_integer()} | {:error, Relay.Error.t()}

  @classes ~w(security transactional operational social marketing system action_required)
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
  @doc "Builds the engage spec of an API client's request, outside any transaction: only campaign and workflow scopes, a TTL, no `security` stop; a workflow is named by its key."
  @spec engage_spec(Relay.Scope.t(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def engage_spec(scope, body) do
    kind = Map.fetch!(@scopes, body["scope_kind"])

    with :ok <- client_may(kind, body),
         {:ok, ref} <- scope_ref(scope, kind, body["scope_ref"]),
         {:ok, expires_at} <- expiry(body["ttl"]),
         {:ok, state} <- state(body) do
      {:ok,
       %{
         scope_kind: kind,
         scope: scope,
         scope_ref: ref,
         channel: body["channel"],
         target: target(body),
         message_class: class(body["message_class"]),
         state: state,
         reason: body["reason"],
         ticket: body["ticket_ref"],
         expires_at: expires_at
       }}
    end
  end

  defp client_may(kind, body) do
    if kind in [:campaign, :workflow] and body["message_class"] != "security" and
         body["no_ttl"] != true,
       do: :ok,
       else: {:error, operator_session_required()}
  end

  defp scope_ref(_scope, _kind, nil), do: field_error("/scope_ref", "required", "name the scope")

  defp scope_ref(scope, :workflow, key) do
    case Relay.Workflow.resolve_published(scope, key) do
      {:ok, {:ok, workflow}} -> {:ok, workflow["workflow_id"]}
      {:ok, :not_published} -> workflow_id(scope, key)
      _ -> {:error, Relay.Error.new(:workflow_not_found, "no workflow has this key")}
    end
  end

  defp scope_ref(_scope, :campaign, ref), do: {:ok, ref}

  defp workflow_id(scope, key) do
    case Relay.Workflow.get(scope, key) do
      {:ok, %{"id" => id}} -> {:ok, id}
      _ -> {:error, Relay.Error.new(:workflow_not_found, "no workflow has this key")}
    end
  end

  # TN-41
  defp expiry(nil), do: field_error("/ttl", "required", "a kill switch needs a TTL")

  defp expiry(ttl) do
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
  @doc "Engages a prepared kill switch inside the request's transaction; `201` with the record."
  @spec engage(map(), String.t()) :: written()
  def engage(spec, client_ref) do
    case KillSwitch.engage_here(spec, %{kind: :api_client, ref: client_ref}) do
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
            created_by_ref: client_ref,
            expires_at: spec.expires_at,
            supersedes_id: nil
          })

        {:ok, {201, [], view(fresh(record))}, generation}

      {:error, reason} ->
        {:error, engage_error(reason)}
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
  @doc "Replaces a kill switch read before, inside the request's transaction; only a tighter state is accepted from an API client."
  @spec replace(map(), map(), String.t()) :: written()
  def replace(record, body, client_ref) do
    with :ok <- if(body["no_ttl"] == true, do: {:error, operator_session_required()}, else: :ok),
         {:ok, state} <- state(body),
         {:ok, expires_at} <- expiry(body["ttl"]) do
      change = %{state: state, reason: body["reason"], expires_at: expires_at}

      case KillSwitch.replace_here(record, change, %{kind: :api_client, ref: client_ref}) do
        {:ok, %{id: id, generation: generation}} ->
          new =
            record
            |> Map.merge(state_fields(%{state: state}))
            |> Map.merge(%{
              id: decode(id),
              reason: body["reason"],
              created_by_ref: client_ref,
              expires_at: expires_at,
              supersedes_id: record.id
            })

          {:ok, {201, [], view(fresh(new))}, generation}

        {:error, reason} ->
          {:error, engage_error(reason)}
      end
    end
  end

  defp engage_error(reason)
       when reason in [
              :forbidden,
              :relax_approval_required,
              :security_approval_required,
              :no_ttl_approval_required,
              :approval_required
            ],
       do: operator_session_required()

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
