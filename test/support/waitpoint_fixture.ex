defmodule RelayTest.WaitpointFixture do
  @moduledoc "SQL-level helpers for mailbox, waitpoint and fan-out tests: recipients, subject keys and function calls with readable defaults."

  use Boundary, top_level?: true, check: [out: false]

  import Relay.SqlCase

  @doc "Creates a recipient of `kind` in the current context and returns its ID."
  @spec member!(map(), String.t()) :: binary()
  def member!(s, kind \\ "agent") do
    recipient_id = id()

    ["created", ^recipient_id] =
      row(
        "SELECT * FROM relay_fn.recipient_create($1, $2, $3, $4, $5, $6, $7, $8)",
        [
          recipient_id,
          kind,
          digest(),
          s.bidx_key,
          :crypto.strong_rand_bytes(40),
          id(),
          :crypto.strong_rand_bytes(60),
          s.wrap_key
        ]
      )

    recipient_id
  end

  @doc "Creates the `notification_content` subject key of a recipient and returns its ID."
  @spec content_key!(map(), binary()) :: binary()
  def content_key!(s, recipient_id) do
    key_id = id()

    ["created", ^key_id] =
      row("SELECT * FROM relay_fn.subject_key_create($1, $2, 'notification_content', $3, $4)", [
        key_id,
        recipient_id,
        :crypto.strong_rand_bytes(60),
        s.wrap_key
      ])

    key_id
  end

  @doc "A tenant in the `test` environment with its keys; the context is set."
  @spec setup!(String.t()) :: map()
  def setup!(environment \\ "test") do
    tenant = tenant!()
    "active" = ctx(tenant, environment)

    %{
      tenant: tenant,
      environment: environment,
      data_key: tenant_key!("data"),
      wrap_key: tenant_key!("dek_wrap"),
      bidx_key: blind_index_key!()
    }
  end

  @doc "Calls `relay_fn.waitpoint_open` with defaults; `opts` overrides any argument by name."
  @spec open(map(), keyword()) :: list()
  def open(s, opts) do
    kind = Keyword.get(opts, :kind, "question")
    question? = kind in ["question", "review"]

    defaults = [
      id: id(),
      kind: kind,
      waiter_kind: "agent",
      waiter_ref: nil,
      mailbox_id: nil,
      match_event_type: "agent.answer",
      correlation_key: "ck-" <> Base.encode16(:crypto.strong_rand_bytes(6)),
      condition: nil,
      response_schema: if(question?, do: %{"type" => "object"}),
      responder_ids: [],
      subject_digest: if(question?, do: digest()),
      content_ct: if(question?, do: "content"),
      claim_text_ct: nil,
      default_response_ct: nil,
      field_key_id: if(question?, do: s.data_key),
      expires_at: {:in, 3_600_000},
      heartbeat_interval_ms: nil,
      escalation_policy_ref: nil,
      surface_policy: nil,
      deliver_to_topics: [],
      tags: [],
      tenant_open_cap: 10_000,
      waiter_open_cap: 1_000,
      traceparent: nil
    ]

    args = Keyword.merge(defaults, opts)

    params =
      for {name, _} <- defaults do
        case {name, Keyword.fetch!(args, name)} do
          {:expires_at, {:in, ms}} -> business_now(ms)
          {_, value} -> value
        end
      end

    row(
      "SELECT * FROM relay_fn.waitpoint_open(#{Enum.map_join(1..length(params), ", ", &"$#{&1}")})",
      params
    )
  end

  @doc "Business time of the current context moved by `ms` milliseconds."
  @spec business_now(integer()) :: DateTime.t()
  def business_now(ms \\ 0) do
    one("SELECT relay_private.business_now() + $1 * interval '1 millisecond'", [ms])
  end

  @doc "Calls `relay_fn.waitpoint_respond` with defaults; `opts` overrides any argument by name."
  @spec respond(binary(), keyword()) :: list()
  def respond(waitpoint_id, opts) do
    defaults = [
      response_id: id(),
      responder_recipient_id: nil,
      responder_actor_ref: "acc_user_1",
      session_actor_ref: "acc_user_1",
      via: "push",
      evidence_level: "relay_session",
      evidence_ref: nil,
      subject_digest: nil,
      value_ct: "value",
      value_key_id: nil,
      value_digest: digest(),
      source_record_id: nil
    ]

    args = Keyword.merge(defaults, opts)
    params = [waitpoint_id | for({name, _} <- defaults, do: Keyword.fetch!(args, name))]

    row(
      "SELECT * FROM relay_fn.waitpoint_respond(#{Enum.map_join(1..length(params), ", ", &"$#{&1}")})",
      params
    )
  end

  @doc "Calls `relay_fn.waitpoint_event_offer`; returns all rows."
  @spec offer(String.t(), String.t(), keyword()) :: [list()]
  def offer(event_type, correlation_key, opts \\ []) do
    rows(
      "SELECT * FROM relay_fn.waitpoint_event_offer($1, $2, $3, $4, $5, $6, $7, NULL, NULL, $8)",
      [
        Keyword.get(opts, :event_id, id()),
        event_type,
        correlation_key,
        Keyword.get(opts, :waiter_kind),
        Keyword.get(opts, :waiter_ref),
        Keyword.get(opts, :record_id, id()),
        nil,
        digest()
      ]
    )
  end

  @doc "Runs `fun` with the context `build` returns, on an admin connection as `relay_owner` inside a transaction that is rolled back, so a test can change rows the functions never change."
  @spec as_owner((-> map()), (map() -> term())) :: term()
  def as_owner(build, fun) do
    admin = connect(:admin)

    try do
      rolled_back(admin, fn ->
        ctx = build.()
        rows("SET LOCAL ROLE relay_owner")
        fun.(ctx)
      end)
    after
      GenServer.stop(admin)
    end
  end

  @doc "Calls `relay_fn.mailbox_append` with defaults; returns `[result, epoch, seq]`."
  @spec append(binary(), keyword()) :: list()
  def append(mailbox_id, opts \\ []) do
    row(
      "SELECT * FROM relay_fn.mailbox_append($1, $2, $3, $4, $5, NULL, NULL, $6, NULL, $7, $8, NULL)",
      [
        Keyword.get_lazy(opts, :id, &id/0),
        mailbox_id,
        Keyword.get(opts, :kind, "message"),
        Keyword.get(opts, :event_type, "inbox.message"),
        Keyword.get(opts, :correlation_key),
        Keyword.get(opts, :payload_ct),
        Keyword.get(opts, :payload_key_id),
        digest()
      ]
    )
  end

  @doc "Opens the mailbox of an owner; returns its ID."
  @spec mailbox!(String.t(), binary()) :: binary()
  def mailbox!(owner_kind, owner_ref) do
    [result, mailbox_id, _stream] =
      row("SELECT * FROM relay_fn.mailbox_ensure($1, $2, $3)", [id(), owner_kind, owner_ref])

    true = result in ["created", "exists"]
    mailbox_id
  end

  @doc "Advances the virtual clock of the current `test` context by `ms`; returns the new offset."
  @spec advance!(pos_integer()) :: integer()
  def advance!(ms) do
    ["advanced", offset, _] =
      row("SELECT * FROM relay_fn.virtual_clock_advance($1, $2, $3, $4, $5, $6)", [
        ms,
        digest() | actor()
      ])

    offset
  end

  @doc "Reads a waitpoint column."
  @spec waitpoint(binary(), String.t()) :: term()
  def waitpoint(waitpoint_id, column),
    do: one("SELECT #{column} FROM relay.waitpoints WHERE id = $1", [waitpoint_id])

  @doc "Lists the event types of a mailbox's records in sequence order."
  @spec mailbox_events(binary()) :: [String.t()]
  def mailbox_events(mailbox_id) do
    "SELECT event_type FROM relay.mailbox_records WHERE mailbox_id = $1 ORDER BY epoch, seq"
    |> rows([mailbox_id])
    |> List.flatten()
  end
end
