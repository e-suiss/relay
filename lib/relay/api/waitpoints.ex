defmodule Relay.Api.Waitpoints do
  @moduledoc """
  Waitpoints on the server API (C-72, AG-7 … AG-16, AG-46, AG-53, AG-62, AG-64): create (`201`), read, list, cancel and the waiter's heartbeat.

  A waitpoint names its interaction when it is created (C-75, AG-8): a `question` or a `review` asks its responders for one response and is of class `action_required`; it carries the response schema, the responder set, the subject digest, the typed content and a structured action list, and a review also carries its evidence pack, whose sensitive values travel as digests. An `event` waitpoint waits for an event and takes none of these. A notification that expects no response is an ordinary event and has no waitpoint. The outcome class and the risk tier are labels of the owner, stored and returned as they came. The responder set is the creator's: it is stored and returned as it was given, never widened or narrowed (AG-12).

  The content, the action list and the evidence pack are sealed as one value, and the claim text and the default response each as their own, under the tenant's data key before the request's transaction, so subject erasure removes them with the waitpoint's personal fields (OP-24). The correlation key is turned into its keyed digests there too and is never stored or returned (AG-65).

  The limits are the contract's `x-relay-limits.waitpoint` (AG-53, AG-70) and every refusal names its limit: the longest wait, the messages a waitpoint may produce (its responders and its topics), the size of a response value, and the open waitpoints of the tenant environment and of the waiter.

  A waitpoint that carries `access_link`, the deep link to the Access approval surface, is an approval-type request: the link is the only action of its inbox and notification items and no channel takes a response to it (AG-32, IN-6, E-16); it is sealed with the content.

  The profile `guardian_approval` is a review that takes no default response; its deadline comes from the creator and is never moved, and expiry produces `waitpoint.expired` alone (AG-62, AG-18).

  Every credential with the operation's scope reads, lists and cancels the waitpoints of its tenant environment (AG-46); an API client's own waitpoint takes a heartbeat only from that client. An agent's narrow scope is checked in `caller/1` once agent credentials carry one (AG-6).
  """

  alias Relay.Api.Duration
  alias Relay.Api.Gate
  alias Relay.Api.Page
  alias Relay.Api.Pagination
  alias Relay.Api.Schema
  alias Relay.Api.Views
  alias Relay.Api.WaitpointPlans
  alias Relay.Scope

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}
  @type caller :: %{
          required(:api_client) => Relay.Id.t() | nil,
          optional(:agent) => Relay.Id.t() | nil
        }

  @dialect "https://json-schema.org/draft/2020-12/schema"
  @max_wait Relay.Limits.seconds!(["waitpoint", "max_wait"])
  @max_messages Relay.Limits.fetch!(["waitpoint", "max_messages"])
  @max_response Relay.Limits.fetch!(["waitpoint", "max_response_bytes"])
  @max_schema 65_536
  @heartbeat_min 1_000
  @heartbeat_max 86_400_000
  @states %{
    "open" => :open,
    "stalled" => :stalled,
    "resolved" => :resolved,
    "expired" => :expired,
    "cancelled" => :cancelled
  }
  @waiters %{"agent" => :agent, "api_client" => :api_client}
  @kinds %{"question" => :question, "review" => :review, "event" => :event}
  @tag ~r/\A[a-z0-9][a-z0-9_.:-]{0,63}\z/
  @channels Relay.Api.Contract.documents()["schemas"]["Channel"]["enum"]
  @asking ~w(response_schema responders subject_digest content actions)
  @asking_only ~w(response_schema responders subject_digest content claim_text default_response
                  actions evidence labels profile escalation_policy surface_policy access_link)
  @unserved ~w(condition)
  @plan_refusals [
    :escalation_policy_not_found,
    :escalation_policy_archived,
    :escalation_responder_outside_set,
    :escalation_tier_limit,
    :surface_recipient_outside_set
  ]
  @sealed ~w(content actions evidence access_link)

  # AG-6
  # AG-46
  @doc "Who calls: the API client of the credential, when the credential names one."
  @spec caller(String.t() | nil, Relay.Id.t() | nil) :: caller()
  def caller(api_client_id, agent_id \\ nil) do
    case Relay.ExternalId.decode(api_client_id, ["cli"]) do
      {:ok, id} -> %{api_client: id, agent: agent_id}
      {:error, _error} -> %{api_client: nil, agent: agent_id}
    end
  end

  # AG-46
  # AG-66
  @doc "Reads the filters of a list request: `state`, `awaiting_response` (the open and stalled waitpoints), `waiter` and `tag`; every invalid one is reported."
  @spec filters(map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def filters(query) do
    checks = [
      states(Map.get(query, "state"), Map.get(query, "awaiting_response")),
      waiter_filter(Map.get(query, "waiter")),
      tag_filter(Map.get(query, "tag"))
    ]

    case for({:error, error} <- checks, do: error) do
      [] -> {:ok, merged(checks)}
      errors -> {:error, invalid(errors)}
    end
  end

  defp merged(checks) do
    for {:ok, part} <- checks, reduce: %{} do
      filter -> Map.merge(filter, part)
    end
  end

  defp states(nil, nil), do: {:ok, %{}}
  defp states(nil, "false"), do: {:ok, %{}}
  defp states(nil, "true"), do: {:ok, %{states: [:open, :stalled]}}

  defp states(nil, _other),
    do: {:error, error("/awaiting_response", "invalid_format", "true or false")}

  defp states(state, nil) when is_map_key(@states, state),
    do: {:ok, %{states: [Map.fetch!(@states, state)]}}

  defp states(_state, nil), do: {:error, error("/state", "unsupported_value", "unknown state")}

  defp states(state, "false"), do: states(state, nil)

  defp states(_state, _awaiting),
    do: {:error, error("/awaiting_response", "conflict", "use state or awaiting_response")}

  defp waiter_filter(nil), do: {:ok, %{}}

  defp waiter_filter(text) when is_binary(text) do
    case {Relay.ExternalId.decode(text, ["agt", "cli"]), text} do
      {{:ok, id}, "agt_" <> _rest} -> {:ok, %{waiter_kind: :agent, waiter_ref: id}}
      {{:ok, id}, "cli_" <> _rest} -> {:ok, %{waiter_kind: :api_client, waiter_ref: id}}
      _other -> {:error, error("/waiter", "invalid_format", "an agt_ or cli_ identifier")}
    end
  end

  defp waiter_filter(_other),
    do: {:error, error("/waiter", "invalid_format", "an agt_ or cli_ identifier")}

  defp tag_filter(nil), do: {:ok, %{}}

  defp tag_filter(tag) do
    if is_binary(tag) and Regex.match?(@tag, tag),
      do: {:ok, %{tag: tag}},
      else: {:error, error("/tag", "invalid_format", "not a tag")}
  end

  # AG-46
  # API-56
  @doc "Lists waitpoints, newest first."
  @spec list(Scope.t(), map(), Pagination.page(), String.t()) :: answer()
  def list(%Scope{} = scope, filter, page, endpoint) do
    paged = Relay.Agents.page_waitpoints(scope, filter, page.cursor, page.limit)

    with {:ok, rows} <- read(paged),
         {:ok, rows} <- read(Relay.Agents.waitpoint_details(scope, rows)),
         {:ok, names} <- names(scope, rows),
         view = &view(&1, names, opened(scope, &1), nil),
         {:ok, body} <- Page.envelope(rows, page, scope, endpoint, view, &position/1),
         do: {:ok, {200, [], body}}
  end

  defp position(row), do: {row.cursor_at, row.id}

  # AG-46
  # WH-68
  @doc "Reads a waitpoint with its responders, its response and, for one a completion notification resolved, the completion."
  @spec get(Scope.t(), Relay.Id.t()) :: answer()
  def get(%Scope{} = scope, id) do
    with {:ok, waitpoint} <- load(scope, id),
         {:ok, completion} <- completion(scope, waitpoint) do
      {:ok, {200, [], view(waitpoint.row, waitpoint.names, waitpoint.opened, completion)}}
    end
  end

  # AG-46
  # OP-24
  @doc "Reads a waitpoint before a request's transaction: its row with responders and response, the external identifiers of its subscribers and its sealed fields, opened. The fields of a waitpoint do not change after creation, so a change made in the transaction answers with them."
  @spec load(Scope.t(), Relay.Id.t()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def load(%Scope{} = scope, id) do
    with {:ok, row} <- found(Relay.Agents.read_waitpoint(scope, id)),
         {:ok, names} <- names(scope, [row]),
         do: {:ok, %{row: row, names: names, opened: opened(scope, row)}}
  end

  defp found({:ok, nil}), do: {:error, not_found()}
  defp found({:ok, row}), do: {:ok, row}
  defp found({:error, _reason}), do: {:error, unavailable()}

  defp read({:ok, value}), do: {:ok, value}
  defp read({:error, _reason}), do: {:error, unavailable()}

  # WH-68
  defp completion(scope, %{row: %{kind: "event", state: "resolved", id: id}}) do
    case Relay.Webhooks.completion_result(scope, id) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, %{outcome: outcome, result: result, completed_at: at}} ->
        {:ok, %{"outcome" => outcome, "result" => result, "completed_at" => at}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  defp completion(_scope, _waitpoint), do: {:ok, nil}

  defp names(_scope, []), do: {:ok, %{}}

  defp names(scope, rows) do
    ids =
      for row <- rows,
          {id, "subscriber"} <- row.responders ++ responder(row.response),
          uniq: true,
          do: id

    read(Relay.Subscribers.external_ids(scope, ids))
  end

  defp responder(nil), do: []
  defp responder(response), do: [{response.responder_recipient_id, response.responder_kind}]

  # AG-8
  # AG-9
  # AG-53
  # AG-62
  # AG-65
  @doc "Prepares a creation before the request's transaction: checks the rules of the waitpoint's kind, profile and limits, names the waiter, finds the responders, computes the correlation digests and seals the personal fields. Every broken field rule is reported."
  @spec prepare(Scope.t(), map(), caller()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def prepare(%Scope{} = scope, body, caller) do
    with :ok <- rules(scope, body),
         {:ok, waiter} <- waiter(Map.get(body, "waiter"), caller),
         {:ok, responders} <- responders(scope, Map.get(body, "responders", [])),
         {:ok, digests} <- digests(scope, body["match"]),
         {:ok, plan} <- WaitpointPlans.prepare(scope, body),
         {:ok, sealed} <- sealed(scope, body) do
      ids = Enum.map(responders, &elem(&1, 0))
      attrs = Map.merge(attrs(body, waiter, ids, digests, sealed), plan)
      names = for {id, name} when is_binary(name) <- responders, into: %{}, do: {id, name}
      {:ok, %{attrs: attrs, names: names, opened: plain(body)}}
    end
  end

  defp rules(scope, body) do
    errors =
      kind_errors(body["kind"], body) ++
        unserved_errors(body) ++
        deadline_errors(scope, body["expires_at"]) ++
        heartbeat_errors(Map.get(body, "heartbeat_interval")) ++
        schema_errors(body) ++
        profile_errors(body) ++
        action_errors(Map.get(body, "actions", [])) ++
        evidence_errors(get_in(body, ["evidence", "fields"]) || []) ++
        message_errors(body)

    if errors == [], do: :ok, else: {:error, invalid(errors)}
  end

  # AG-8
  # C-75
  defp kind_errors("event", body) do
    for field <- @asking_only,
        Map.has_key?(body, field),
        do: error("/" <> field, "not_allowed", "an event waitpoint takes no " <> field)
  end

  defp kind_errors(kind, body) do
    missing =
      for field <- @asking,
          not Map.has_key?(body, field),
          do: error("/" <> field, "required", "a question or a review carries " <> field)

    missing ++ empty_errors(body) ++ review_errors(kind, Map.has_key?(body, "evidence"))
  end

  defp empty_errors(%{"responders" => []}),
    do: [error("/responders", "too_short", "a question or a review has a responder")]

  defp empty_errors(_body), do: []

  defp review_errors("review", false),
    do: [error("/evidence", "required", "a review carries its evidence pack")]

  defp review_errors("question", true),
    do: [error("/evidence", "not_allowed", "only a review carries an evidence pack")]

  defp review_errors(_kind, _evidence?), do: []

  defp unserved_errors(body) do
    for field <- @unserved,
        Map.has_key?(body, field),
        do: error("/" <> field, "not_allowed", field <> " is not taken by this operation")
  end

  # AG-9
  # AG-53
  defp deadline_errors(scope, text) do
    with {:ok, at, _offset} <- DateTime.from_iso8601(text),
         now = Relay.Clock.business_now(scope),
         :gt <- DateTime.compare(at, now) do
      seconds = DateTime.diff(at, now)

      if seconds > @max_wait,
        do: [over("/expires_at", limit_name("max_wait"), @max_wait, seconds)],
        else: []
    else
      {:error, _reason} -> [error("/expires_at", "invalid_format", "not a timestamp")]
      _past -> [error("/expires_at", "too_short", "the deadline is not in the future")]
    end
  end

  # AG-15
  defp heartbeat_errors(nil), do: []

  defp heartbeat_errors(text) do
    case Duration.to_ms(text) do
      {:ok, ms} when ms < @heartbeat_min ->
        [error("/heartbeat_interval", "too_short", "at least PT1S")]

      {:ok, ms} when ms > @heartbeat_max ->
        [error("/heartbeat_interval", "too_long", "at most P1D")]

      {:ok, _ms} ->
        []

      :error ->
        [error("/heartbeat_interval", "invalid_format", "weeks, days, hours, minutes, seconds")]
    end
  end

  # AG-11
  # AG-53
  # INV-31
  defp schema_errors(%{"response_schema" => schema} = body) do
    cond do
      byte_size(Jason.encode!(schema)) > @max_schema ->
        [error("/response_schema", "too_long", "at most #{@max_schema} bytes")]

      match?({:error, _error}, root(schema)) ->
        [error("/response_schema", "invalid_format", "not a JSON Schema 2020-12 document")]

      true ->
        default_errors(schema, body)
    end
  end

  defp schema_errors(_body), do: []

  defp default_errors(schema, %{"default_response" => value}) do
    case check_response(schema, value) do
      :ok -> []
      {:error, errors} -> for e <- errors, do: %{e | pointer: "/default_response" <> e.pointer}
    end
  end

  defp default_errors(_schema, _body), do: []

  # AG-11
  # AG-53
  # INV-31
  @doc "Checks a response value against a waitpoint's response schema (JSON Schema 2020-12) and the response size limit, before anything is recorded; every failure is a field error whose pointer is in the value."
  @spec check_response(map(), term()) :: :ok | {:error, [map(), ...]}
  def check_response(schema, value) when is_map(schema) do
    size = byte_size(Jason.encode!(value))

    with true <- size <= @max_response || {:error, :size},
         {:ok, root} <- root(schema),
         :ok <- Schema.validate(root, value) do
      :ok
    else
      {:error, :size} ->
        {:error, [over("", limit_name("max_response_bytes"), @max_response, size)]}

      {:error, %Relay.Error{details: %{errors: [_ | _] = errors}}} ->
        {:error, errors}

      {:error, _unbuildable} ->
        {:error, [error("", "invalid_format", "the response schema cannot be read")]}
    end
  end

  defp root(%{"$schema" => dialect}) when dialect != @dialect, do: {:error, :dialect}

  defp root(schema) do
    JSV.build(schema, default_meta: @dialect)
  rescue
    _error -> {:error, :unbuildable}
  end

  # AG-62
  # AG-18
  defp profile_errors(%{"profile" => "guardian_approval"} = body) do
    kind =
      if body["kind"] == "review",
        do: [],
        else: [error("/profile", "not_allowed", "guardian_approval is a review")]

    default =
      if Map.has_key?(body, "default_response"),
        do: [error("/default_response", "not_allowed", "guardian_approval has no default")],
        else: []

    kind ++ default
  end

  defp profile_errors(_body), do: []

  # AG-8
  defp action_errors(actions) do
    ids = Enum.map(actions, & &1["id"])

    for {id, index} <- Enum.with_index(ids),
        id in Enum.take(ids, index),
        do: error("/actions/#{index}/id", "conflict", "an action id is used once")
  end

  # AG-8
  defp evidence_errors(fields) do
    for {field, index} <- Enum.with_index(fields),
        error <- evidence_error(field, "/evidence/fields/#{index}"),
        do: error
  end

  defp evidence_error(%{"value" => _value, "digest" => _digest}, at),
    do: [error(at <> "/digest", "conflict", "a field carries its value or its digest")]

  defp evidence_error(%{"sensitive" => true, "value" => _value}, at),
    do: [error(at <> "/value", "not_allowed", "a sensitive value travels as its digest")]

  defp evidence_error(%{"value" => _value}, _at), do: []
  defp evidence_error(%{"digest" => _digest}, _at), do: []

  defp evidence_error(_neither, at),
    do: [error(at <> "/value", "required", "a field carries its value or its digest")]

  # AG-53
  defp message_errors(body) do
    tiers = get_in(body, ["escalation_policy", "tiers"]) || []
    escalations = Enum.sum(for tier <- tiers, do: 1 + Map.get(tier, "repeat", 0))
    direct = length(Map.get(body, "responders", [])) + length(Map.get(body, "deliver_to", []))
    count = direct + escalations

    if count > @max_messages,
      do: [over("/responders", limit_name("max_messages"), @max_messages, count)],
      else: []
  end

  # AG-6
  # E-29
  defp waiter(nil, %{agent: <<_::128>> = id}), do: {:ok, {:agent, id}}

  defp waiter(%{"kind" => "agent", "id" => text}, %{agent: <<_::128>> = id}) do
    case waiter_id(:agent, text, "agt") do
      {:ok, {:agent, ^id}} = own -> own
      {:ok, _other} -> {:error, invalid([error("/waiter/id", "not_allowed", "not the caller")])}
      {:error, _error} = error -> error
    end
  end

  defp waiter(%{"kind" => _other}, %{agent: <<_::128>>}),
    do: {:error, invalid([error("/waiter", "not_allowed", "an agent waits for itself")])}

  # AG-64
  defp waiter(nil, %{api_client: nil}),
    do: {:error, invalid([error("/waiter", "required", "the credential names no API client")])}

  defp waiter(nil, %{api_client: id}), do: {:ok, {:api_client, id}}

  defp waiter(%{"kind" => "agent", "id" => text}, _caller), do: waiter_id(:agent, text, "agt")

  defp waiter(%{"kind" => "api_client", "id" => text}, %{api_client: caller}) do
    case waiter_id(:api_client, text, "cli") do
      {:ok, {:api_client, ^caller}} = own -> own
      {:ok, _other} -> {:error, invalid([error("/waiter/id", "not_allowed", "not the caller")])}
      {:error, _error} = error -> error
    end
  end

  defp waiter_id(kind, text, prefix) do
    case Relay.ExternalId.decode(text, [prefix]) do
      {:ok, id} ->
        {:ok, {kind, id}}

      {:error, _error} ->
        {:error, invalid([error("/waiter/id", "invalid_format", "not a #{prefix}_ identifier")])}
    end
  end

  # AG-12
  defp responders(scope, responders) do
    found =
      for {responder, index} <- Enum.with_index(responders),
          do: responder(scope, responder, "/responders/#{index}/id")

    case for({:error, error} <- found, do: error) do
      [] -> {:ok, for({:ok, pair} <- found, do: pair)}
      [:unavailable | _rest] -> {:error, unavailable()}
      errors -> {:error, unknown(for(%{} = error <- errors, do: error))}
    end
  end

  defp responder(scope, %{"kind" => "subscriber", "id" => external_id}, at) do
    case Relay.Subscribers.locate(scope, external_id) do
      {:ok, nil} -> {:error, error(at, "not_found", "unknown subscriber")}
      {:ok, id} -> {:ok, {id, external_id}}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp responder(_scope, %{"kind" => "agent", "id" => text}, at) do
    case Relay.ExternalId.decode(text, ["agt"]) do
      {:ok, id} -> {:ok, {id, nil}}
      {:error, _error} -> {:error, error(at, "invalid_format", "not an agt_ identifier")}
    end
  end

  # AG-65
  defp digests(scope, %{"type" => type, "correlation_key" => key}) do
    case Relay.Agents.correlation_digests(scope, type, key) do
      {:ok, digests} -> {:ok, digests}
      {:error, _error} -> {:error, unavailable()}
    end
  end

  # OP-24
  # TN-27
  defp sealed(scope, body) do
    values = [
      {"content_ct", envelope(body)},
      {"claim_text_ct", Map.get(body, "claim_text")},
      {"default_response_ct", default(body)}
    ]

    case for({column, value} when value != nil <- values, do: {column, value}) do
      [] -> {:ok, %{}}
      present -> seal(scope, present)
    end
  end

  defp envelope(body) do
    case Map.take(body, @sealed) do
      empty when empty == %{} -> nil
      fields -> Jason.encode!(fields)
    end
  end

  defp default(%{"default_response" => value}), do: Jason.encode!(value)
  defp default(_body), do: nil

  defp seal(scope, values) do
    case Relay.Tenancy.active_tenant_key(scope, :data) do
      {:ok, key_id} ->
        start = {:ok, %{field_key_id: key_id}}
        Enum.reduce_while(values, start, &seal_value(scope, key_id, &1, &2))

      {:error, _error} ->
        {:error, unavailable()}
    end
  end

  defp seal_value(scope, key_id, {column, value}, {:ok, done}) do
    case Relay.Tenancy.encrypt_field(field(scope, column, key_id), value) do
      {:ok, ct} -> {:cont, {:ok, Map.put(done, column, ct)}}
      {:error, _error} -> {:halt, {:error, unavailable()}}
    end
  end

  defp field(scope, column, key_id) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: nil,
      retention_class: :notification_content,
      table: "waitpoints",
      column: column,
      key_id: key_id
    }
  end

  defp attrs(body, {waiter_kind, waiter_ref}, responder_ids, digests, sealed) do
    {:ok, expires_at, _offset} = DateTime.from_iso8601(body["expires_at"])

    %{
      kind: Map.fetch!(@kinds, body["kind"]),
      waiter_kind: waiter_kind,
      waiter_ref: waiter_ref,
      match_event_type: body["match"]["type"],
      correlation_digests: digests,
      response_schema: Map.get(body, "response_schema"),
      responder_ids: responder_ids,
      subject_digest: digest_bytes(Map.get(body, "subject_digest")),
      content_ct: Map.get(sealed, "content_ct"),
      claim_text_ct: Map.get(sealed, "claim_text_ct"),
      default_response_ct: Map.get(sealed, "default_response_ct"),
      field_key_id: Map.get(sealed, :field_key_id),
      expires_at: expires_at,
      heartbeat_interval_ms: heartbeat_ms(Map.get(body, "heartbeat_interval")),
      deliver_to_topics: for(%{"topic" => key} <- Map.get(body, "deliver_to", []), do: key),
      tags: Map.get(body, "tags", []),
      description: %{
        profile: profile(Map.get(body, "profile")),
        outcome_class: get_in(body, ["labels", "outcome_class"]),
        risk_tier: get_in(body, ["labels", "risk_tier"]),
        correlation_id: Map.get(body, "correlation_id")
      }
    }
  end

  defp profile("guardian_approval"), do: :guardian_approval
  defp profile(nil), do: nil

  defp heartbeat_ms(nil), do: nil

  defp heartbeat_ms(text) do
    {:ok, ms} = Duration.to_ms(text)
    ms
  end

  defp digest_bytes(nil), do: nil
  defp digest_bytes("sha256:" <> hex), do: Base.decode16!(hex, case: :lower)

  defp plain(body),
    do: Map.take(body, @sealed ++ ["claim_text", "default_response", "surface_policy"])

  # C-72
  # AG-9
  # AG-12
  # AG-53
  @doc "Opens a prepared waitpoint inside the request's transaction; `201` with its view. Its topics must exist and be active, and a refusal of the open limits names the limit that was reached."
  @spec create(Scope.t(), map()) :: answer()
  def create(%Scope{} = scope, %{attrs: attrs} = prepared) do
    id = Relay.Id.generate()

    with :ok <- topics(attrs.deliver_to_topics) do
      case Relay.Agents.open_waitpoint_in(scope, Map.put(attrs, :id, id)) do
        %{result: :opened} -> created(id, prepared)
        %{result: result} -> {:error, refused(result, attrs)}
      end
    end
  end

  defp created(id, prepared) do
    row = Relay.Agents.read_waitpoint_in(id)
    location = "/v1/waitpoints/" <> Views.id("wp", id)
    {:ok, {201, [{"location", location}], view(row, prepared.names, prepared.opened, nil)}}
  end

  # AG-7
  defp topics(keys) do
    errors =
      for {key, index} <- Enum.with_index(keys),
          error <- topic_error(Relay.Topics.fetch(key), "/deliver_to/#{index}/topic"),
          do: error

    if errors == [], do: :ok, else: {:error, invalid(errors)}
  end

  defp topic_error(nil, at), do: [error(at, "not_found", "no topic has this key")]
  defp topic_error(%{"state" => "active"}, _at), do: []
  defp topic_error(_archived, at), do: [error(at, "not_allowed", "the topic is archived")]

  # AG-12
  # AG-17
  # AG-63
  defp refused(result, attrs) when result in @plan_refusals,
    do: WaitpointPlans.refusal(result, attrs)

  defp refused(:active_exists, _attrs) do
    message = "the waiter already waits for this event type and correlation key"
    Relay.Error.new(:resource_conflict, message)
  end

  defp refused(:exists, _attrs),
    do: Relay.Error.new(:resource_conflict, "the waitpoint exists")

  defp refused(:expires_invalid, _attrs),
    do: invalid([over("/expires_at", limit_name("max_wait"), @max_wait, nil)])

  defp refused(:condition_unsupported, _attrs),
    do: invalid([error("/condition", "not_allowed", "a condition is not taken")])

  defp refused(:limit_exceeded, attrs) do
    counted = Relay.Agents.open_waitpoints_in()
    tenant = Map.get(attrs, :tenant_open_cap, counted.tenant)
    waiter = Map.get(attrs, :waiter_open_cap, counted.waiter)

    {name, limit} =
      if counted.open + 1 > tenant,
        do: {limit_name("max_open_per_environment"), tenant},
        else: {limit_name("max_open_per_waiter"), waiter}

    message = "the limit of open waitpoints is reached"
    Relay.Error.new(:waitpoint_limit_reached, message, %{limit: limit, limit_name: name})
  end

  defp refused(:waiter_not_found, %{waiter_kind: :agent}),
    do: Relay.Error.new(:agent_not_found, "no agent has this id")

  defp refused(:waiter_not_found, _attrs),
    do: invalid([error("/waiter", "not_found", "the waiter has no active mailbox")])

  defp refused(:responder_not_found, _attrs),
    do: Relay.Error.new(:recipient_not_found, "a responder does not exist")

  defp refused(:responder_is_waiter, _attrs),
    do: invalid([error("/responders", "conflict", "the waiter is never a responder")])

  defp refused(:tenant_inactive, _attrs),
    do: Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")

  # C-72
  # AG-46
  @doc "Cancels an open or stalled waitpoint with a reason inside the request's transaction; `loaded` is what `load/2` read before it. A closed waitpoint does not change."
  @spec cancel(Scope.t(), map(), String.t(), Relay.Actor.t()) :: answer()
  def cancel(%Scope{} = scope, %{row: %{id: id}} = loaded, reason, actor) do
    digest = Gate.digest(scope, "waitpoint.cancelled", Relay.Id.to_string(id))

    case Relay.Agents.cancel_waitpoint_in(id, reason, digest, actor) do
      :cancelled -> changed(id, loaded)
      :already_terminal -> {:error, closed()}
      :not_found -> {:error, not_found()}
    end
  end

  # AG-10
  # AG-15
  # INV-32
  @doc "Records the waiter's heartbeat inside the request's transaction; a stalled waitpoint is open again. An API client's own waitpoint takes it only from that client."
  @spec heartbeat(map(), caller()) :: answer()
  def heartbeat(%{row: %{waiter_kind: kind, waiter_ref: waiter}}, %{agent: <<_::128>> = agent})
      when kind != "agent" or waiter != agent do
    {:error, heartbeat_refused("only the waiter sends its heartbeat")}
  end

  def heartbeat(%{row: %{waiter_kind: "api_client", waiter_ref: waiter}}, %{api_client: caller})
      when waiter != caller do
    {:error, heartbeat_refused("only the waiter sends its heartbeat")}
  end

  def heartbeat(%{row: %{id: id, waiter_kind: kind, waiter_ref: waiter}} = loaded, _caller) do
    case Relay.Agents.heartbeat_in(id, Map.fetch!(@waiters, kind), waiter) do
      {result, _due_at} when result in [:renewed, :reopened] -> changed(id, loaded)
      {:no_heartbeat, _due_at} -> {:error, heartbeat_refused("the waitpoint has no heartbeat")}
      {:already_terminal, _due_at} -> {:error, closed()}
      {:not_waiter, _due_at} -> {:error, heartbeat_refused("only the waiter sends its heartbeat")}
      {:not_found, _due_at} -> {:error, not_found()}
    end
  end

  defp changed(id, loaded) do
    case Relay.Agents.read_waitpoint_in(id) do
      nil -> {:error, not_found()}
      row -> {:ok, {200, [], view(row, loaded.names, loaded.opened, nil)}}
    end
  end

  # AG-8
  # AG-12
  # AG-25
  # AG-26
  # AG-65
  @doc "The API view of a waitpoint with its responders and response: `names` are the external identifiers of its subscribers, `opened` its sealed fields in clear and `completion` the completion that resolved it. The correlation key is never part of it."
  @spec view(map(), map(), map(), map() | nil) :: map()
  def view(w, names, opened, completion) do
    %{
      "object" => "waitpoint",
      "id" => Views.id("wp", w.id),
      "kind" => w.kind,
      "waiter" => %{"kind" => w.waiter_kind, "id" => waiter_id(w)},
      "match" => %{"type" => w.match_event_type},
      "expires_at" => w.expires_at,
      "deliver_to" => Enum.map(w.deliver_to_topics, &%{"topic" => &1}),
      "tags" => w.tags,
      "escalation_policy" => WaitpointPlans.escalation_view(w.escalation_policy_ref),
      "state" => w.state,
      "response" => response(w.response, names),
      "completion" => completion,
      "created_at" => w.created_at,
      "state_changed_at" => w.state_changed_at,
      "heartbeat_due_at" => w.heartbeat_due_at,
      "cancel_reason" => w.cancel_reason
    }
    |> Map.merge(asking(w, names))
    |> Views.put_unless_nil("correlation_id", w.correlation_id)
    |> Views.put_unless_nil("heartbeat_interval", interval(w.heartbeat_interval_ms))
    |> Map.merge(opened)
  end

  defp waiter_id(%{waiter_kind: "agent", waiter_ref: id}), do: Views.id("agt", id)
  defp waiter_id(%{waiter_ref: id}), do: Views.id("cli", id)

  # AG-8
  # C-75
  defp asking(%{kind: "event"}, _names), do: %{}

  defp asking(w, names) do
    %{
      "message_class" => "action_required",
      "response_schema" => w.response_schema,
      "responders" => Enum.map(w.responders, &responder_view(&1, names)),
      "subject_digest" => digest_text(w.subject_digest)
    }
    |> Views.put_unless_nil("profile", w.profile)
    |> Views.put_unless_nil("labels", labels(w))
  end

  defp labels(%{outcome_class: nil, risk_tier: nil}), do: nil

  defp labels(w) do
    %{}
    |> Views.put_unless_nil("outcome_class", w.outcome_class)
    |> Views.put_unless_nil("risk_tier", w.risk_tier)
  end

  # AG-12
  defp responder_view({id, "agent"}, _names),
    do: %{"kind" => "agent", "id" => Views.id("agt", id)}

  defp responder_view({id, _subscriber}, names),
    do: %{"kind" => "subscriber", "id" => Map.get(names, id) || Views.id("sub", id)}

  # AG-25
  # AG-26
  defp response(nil, _names), do: nil

  defp response(r, names) do
    prefix = Views.recipient_prefix(r.responder_kind)
    name = Map.get(names, r.responder_recipient_id)

    responder = %{
      "recipient_id" => Views.id(prefix, r.responder_recipient_id),
      "kind" => r.responder_kind
    }

    %{
      "id" => Views.id("wpr", r.id),
      "responder" => Views.put_unless_nil(responder, "external_id", name),
      "channel" => if(r.via in @channels, do: r.via),
      "evidence_level" => r.evidence_level,
      "responded_at" => r.responded_at,
      "response_digest" => digest_text(r.value_digest)
    }
  end

  defp digest_text(nil), do: nil
  defp digest_text(digest), do: "sha256:" <> Base.encode16(digest, case: :lower)

  defp interval(nil), do: nil

  defp interval(ms),
    do: Duration.iso(%Postgrex.Interval{months: 0, days: 0, secs: div(ms, 1_000)})

  # OP-24
  # TN-27
  defp opened(scope, w) do
    envelope =
      case open(scope, w, "content_ct", w.content_ct) do
        {:ok, %{} = fields} -> Map.take(fields, @sealed)
        _absent_or_unreadable -> %{}
      end

    claim = open_text(scope, w, "claim_text_ct", w.claim_text_ct)
    default = open(scope, w, "default_response_ct", w.default_response_ct)

    envelope
    |> put_opened("claim_text", claim)
    |> put_opened("default_response", default)
    |> put_opened("surface_policy", surface(scope, w))
  end

  # AG-63
  defp surface(scope, w) do
    case WaitpointPlans.surface_view(scope, w.surface_policy) do
      {:ok, %{} = policy} -> {:ok, policy}
      _absent_or_unreadable -> :absent
    end
  end

  defp put_opened(map, key, {:ok, value}), do: Map.put(map, key, value)
  defp put_opened(map, _key, _absent), do: map

  defp open(scope, w, column, ct) do
    with {:ok, text} <- open_text(scope, w, column, ct), do: Jason.decode(text)
  end

  defp open_text(_scope, _w, _column, nil), do: :absent

  defp open_text(scope, w, column, ct) do
    case Relay.Tenancy.decrypt_field(field(scope, column, w.field_key_id), ct) do
      {:ok, plain} -> {:ok, Relay.Redacted.expose(plain)}
      {:error, _error} -> :absent
    end
  end

  defp over(pointer, name, limit, nil) do
    detail = "over the limit x-relay-limits " <> name
    %{pointer: pointer, code: "too_long", detail: detail, limit: limit}
  end

  defp over(pointer, name, limit, actual),
    do: Map.put(over(pointer, name, limit, nil), :actual, actual)

  defp limit_name(key), do: Enum.join(["waitpoint", key], ".")

  defp error(pointer, code, detail), do: %{pointer: pointer, code: code, detail: detail}

  defp invalid(errors),
    do: Relay.Error.new(:validation_failed, "the request breaks a field rule", %{errors: errors})

  defp unknown(errors),
    do: Relay.Error.new(:recipient_not_found, "a responder does not exist", %{errors: errors})

  @doc "The error of an unknown waitpoint."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:waitpoint_not_found, "no waitpoint has this id")

  defp closed, do: Relay.Error.new(:waitpoint_closed, "the waitpoint is closed")

  defp heartbeat_refused(message), do: Relay.Error.new(:waitpoint_heartbeat_refused, message)

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
