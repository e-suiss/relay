defmodule Relay.Api.AgentCeilings do
  @moduledoc """
  The agent ceiling on the server and operator APIs (AG-49, E-43, E-44, TN-21, TN-47): the owner of an agent lists the notifications held at the agent's ceiling, decides on them and lifts a stop.

  A decision answers an `agent.ceiling_exceeded` event, named by its event identifier, and applies to every notification held for the agent: `send_all` releases them, `cancel` cancels them and `stop` cancels them and stops the agent. It is written with its audit record (`agent.ceiling_decided`) in the request's transaction and applied in the background. The same decision again returns the first; a different one is `ceiling_decision_conflict`. Releasing held notifications needs a step-up: an API client's `send_all` is `auth_operator_session_required`, and a tenant administrator gives it on the operator surface (`decide_as_operator/4`). Lifting a stop is audited as `agent.resumed`; resuming an agent that is not stopped changes nothing.
  """

  alias Relay.Agents.Ceiling
  alias Relay.Api.Gate
  alias Relay.Api.Page
  alias Relay.Api.Views
  alias Relay.Scope

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @states ~w(held released cancelled expired)

  # AG-49
  @doc "The API view of a held notification row."
  @spec hold_view(map()) :: map()
  def hold_view(h) do
    %{
      "object" => "ceiling_hold",
      "notification_id" => Views.id("ntf", h["notification_id"]),
      "agent_id" => Views.id("agt", h["agent_ref"]),
      "ceiling_event_id" => Views.id("oev", h["ceiling_event_id"]),
      "rule_id" => h["rule_id"],
      "state" => h["state"],
      "held_at" => h["held_at"],
      "expires_at" => h["expires_at"],
      "decision_id" => Views.id("acd", h["decision_id"]),
      "decided_at" => h["decided_at"]
    }
  end

  # AG-49
  @doc "The API view of a decision row with the run state of its agent."
  @spec decision_view(map(), String.t()) :: map()
  def decision_view(d, agent_state) do
    %{
      "object" => "ceiling_decision",
      "id" => Views.id("acd", d["id"]),
      "agent_id" => Views.id("agt", d["agent_ref"]),
      "ceiling_event_id" => Views.id("oev", d["ceiling_event_id"]),
      "decision" => d["decision"],
      "decision_ref" => d["decision_ref"],
      "note" => d["note"],
      "applied_count" => d["applied_count"],
      "agent_state" => agent_state,
      "decided_at" => d["decided_at"]
    }
  end

  # AG-49
  @doc "The API view of an agent's run state."
  @spec state_view(map()) :: map()
  def state_view(state) do
    %{
      "object" => "agent_state",
      "agent_id" => Views.id("agt", state.agent_ref),
      "state" => state.state,
      "decision_ref" => state.decision_ref,
      "changed_at" => state.changed_at
    }
  end

  # AG-49
  @doc "Reads the `state` filter of a list request."
  @spec filters(map()) :: {:ok, String.t() | nil} | {:error, Relay.Error.t()}
  def filters(query) do
    case Map.get(query, "state") do
      state when state == nil or state in @states -> {:ok, state}
      _other -> {:error, Gate.field_error("/state", "unsupported_value", "unknown state")}
    end
  end

  # AG-49
  # INV-3
  # API-56
  @doc "Lists the held notifications of an agent, newest first."
  @spec list(Scope.t(), Relay.Id.t(), String.t() | nil, map(), String.t()) :: answer()
  def list(%Scope{} = scope, agent_ref, state, page, endpoint) do
    case Ceiling.list_holds(scope, agent_ref, state, page.cursor, page.limit) do
      {:ok, nil} ->
        {:error, not_found()}

      {:ok, rows} ->
        paged(Page.envelope(rows, page, scope, endpoint, &hold_view/1, &position/1))

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # AG-49
  # TN-21
  # TN-47
  @doc "Records the owner's decision inside the request's transaction; a release by an actor without a step-up reference is `auth_operator_session_required`."
  @spec decide(Scope.t(), Relay.Id.t(), map(), Relay.Actor.t()) :: answer()
  def decide(%Scope{} = scope, agent_ref, body, actor) do
    case Relay.ExternalId.decode(body["ceiling_event_id"], ["oev"]) do
      {:ok, event_id} -> decided(scope, agent_ref, event_id, body, actor)
      {:error, _error} -> {:error, event_not_found()}
    end
  end

  defp decided(scope, agent_ref, event_id, body, actor) do
    digest = Gate.digest(scope, "agent.ceiling_decided", Relay.Id.to_string(event_id))

    decision = %{
      agent_ref: agent_ref,
      ceiling_event_id: event_id,
      decision: body["decision"],
      decision_ref: body["decision_ref"],
      note: body["note"]
    }

    case Ceiling.decide_here(scope, decision, digest, actor) do
      {result, row} when result in [:decided, :exists] ->
        %{state: agent_state} = Ceiling.run_state_here(agent_ref)
        {:ok, {201, [], decision_view(row, agent_state)}}

      {:conflict, _row} ->
        message = "a different decision was already recorded for this ceiling event"
        {:error, Relay.Error.new(:ceiling_decision_conflict, message)}

      {:step_up_required, nil} ->
        message = "releasing held notifications needs an operator session with step-up"
        {:error, Relay.Error.new(:auth_operator_session_required, message)}

      {:agent_not_found, nil} ->
        {:error, not_found()}

      {:ceiling_event_not_found, nil} ->
        {:error, event_not_found()}
    end
  end

  # AG-49
  # TN-21
  @doc "Records the decision of a tenant administrator with step-up, in a transaction of its own; `{:ok, {201, view}}`."
  @spec decide_as_operator(Scope.t(), Relay.Id.t(), map(), Relay.Actor.t()) ::
          {:ok, {201, map()}} | {:error, Relay.Error.t()}
  def decide_as_operator(%Scope{} = scope, agent_ref, body, actor) do
    work = fn _status -> decide(scope, agent_ref, body, actor) end

    case Ceiling.in_scope(scope, work) do
      {:ok, {:ok, {201, [], view}}} -> {:ok, {201, view}}
      {:ok, {:error, %Relay.Error{} = error}} -> {:error, error}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # AG-49
  # TN-47
  @doc "Lifts a stop decision on an agent inside the request's transaction; resuming an agent that is not stopped returns its state unchanged."
  @spec resume(Scope.t(), Relay.Id.t(), map(), Relay.Actor.t()) :: answer()
  def resume(%Scope{} = scope, agent_ref, body, actor) do
    digest = Gate.digest(scope, "agent.resumed", Relay.Id.to_string(agent_ref))

    case Ceiling.resume_here(agent_ref, body["decision_ref"], digest, actor) do
      {:agent_not_found, nil} -> {:error, not_found()}
      {_resumed_or_unchanged, state} -> {:ok, {200, [], state_view(state)}}
    end
  end

  defp paged({:ok, body}), do: {:ok, {200, [], body}}
  defp paged({:error, %Relay.Error{} = error}), do: {:error, error}

  defp position(row), do: {row["cursor_at"], row["id"]}

  @doc "The error of an unknown agent identifier."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:agent_not_found, "no agent has this id")

  defp event_not_found do
    message = "ceiling_event_id names no agent.ceiling_exceeded event of this agent"
    Relay.Error.new(:ceiling_event_not_found, message)
  end

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
