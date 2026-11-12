defmodule Relay.Api.Campaigns do
  @moduledoc """
  Campaigns on the server API (API-35, WF-44, WF-34, WF-62, X-14, OP-47, T-23): a large list or topic send through its own endpoint, prepared first and then triggered.

    * A campaign names a published workflow, the event `data` its templates render, a required `deadline` at most P31D ahead and the `expected_count` the tenant declares. Its audience is a list of subscriber identifiers given at creation or added in parts of at most 5,000 while it is a draft, or a topic; there is no attribute query (WF-54). The data is sealed under the tenant data key. A `security` workflow is not a campaign.
    * Preparation freezes the audience and the workflow version, then a chain of jobs evaluates every member's channels in a dry run of the policy lattice: the recipients it reaches, the channel deliveries it would send or defer, the ones it drops by `rule_id`, and the cost estimate from the active provider's price table (X-14). Each member's `dedup_key` was fixed when it was added (WF-44). A topic audience is frozen at preparation from the topic's active subscribers and, for a child topic, its active parent's (`Relay.Topics.recipients/2`, WF-52).
    * The five members first in identifier order are the deterministic render samples; their workflow preview is approved by its digest, and the trigger renders them again and refuses a changed set (WF-62). A frozen audience above 1.5 times `expected_count` needs a tenant administrator's approval on the operator surface.
    * The trigger only sends: its stages open as fan-outs of the campaign's lane (`Relay.Platform.create_fanout/2`, T-23, T-91), each sub-batch a send job that accepts one event per member with the member's `dedup_key` and `expires_at` at the deadline, so the lattice, quotas, rate and provider limits apply as to any event and the send rate is never raised to meet the deadline (WF-34). An audience above 100,000 opens 1 % → 10 % → 100 %, PT15M apart (WF-62). The progress is the campaign record; a running campaign pauses under its campaign kill switch and resumes when the switch is released, and pauses by itself when a channel passes its alarm threshold, after which a tenant administrator resumes it (OP-47). At the deadline the members left are counted `expired` and `campaign.expired` is published. A campaign can be cancelled at any time.
  """

  alias Relay.Api.Campaigns.Plan
  alias Relay.Api.Campaigns.PrepareJob
  alias Relay.Api.Campaigns.Store
  alias Relay.Api.Campaigns.TickJob
  alias Relay.Api.Page
  alias Relay.Api.Previews
  alias Relay.Api.Schema
  alias Relay.Api.Views

  @prefix "cmp"
  @closed ~w(completed partial cancelled)
  @max_audience 10_000_000
  @part 5_000

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}
  @type planned :: map()
  @type error :: {:error, Relay.Error.t()}
  @type digest :: <<_::256>>

  @doc "The external identifier prefix of a campaign."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "The error of an unknown campaign."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:campaign_not_found, "no campaign has this id")

  # API-35
  # WF-34
  # WF-54
  @doc "Checks a campaign request and prepares its writes outside any transaction: the deadline, the audience, the published workflow and its event schema, the sealed data and the blind indexes of the listed recipients."
  @spec plan_create(map(), map()) :: {:ok, planned()} | {:error, Relay.Error.t()}
  def plan_create(%{scope: scope} = ctx, body) do
    with {:ok, deadline} <- deadline(scope, body["deadline"]),
         {:ok, audience} <- audience(body),
         {:ok, workflow} <- workflow(scope, body["workflow"]),
         :ok <- campaign_class(workflow),
         data = body["data"] || %{},
         :ok <- event_data(workflow, data),
         {:ok, sealed} <- seal(scope, data),
         {:ok, bidxs} <- indexes(scope, audience) do
      {:ok,
       %{
         id: Relay.Id.generate(),
         name: body["name"],
         workflow_key: body["workflow"],
         audience: audience,
         sealed: sealed,
         bidxs: bidxs,
         expected_count: body["expected_count"],
         deadline: deadline,
         api_client_ref: Map.get(ctx, :api_client_id)
       }}
    end
  end

  # API-35
  @doc "Records a planned campaign and its listed recipients inside the request's transaction; `201` with its view."
  @spec create(Relay.Scope.t(), planned()) :: answer()
  def create(_scope, %{id: id} = plan) do
    {kind, topic} =
      case plan.audience do
        {:topic, key} -> {"topic", key}
        {:list, _ids} -> {"list", nil}
      end

    attrs = %{
      id: id,
      name: plan.name,
      workflow_key: plan.workflow_key,
      audience_kind: kind,
      topic_key: topic,
      data_key_id: plan.sealed.key_id,
      data_ct: plan.sealed.data_ct,
      api_client_ref: plan.api_client_ref,
      expected_count: plan.expected_count,
      deadline: plan.deadline
    }

    with :created <- Store.create(attrs),
         {:ok, _added} <- add(id, plan.bidxs),
         {:ok, view} <- current_view(id) do
      {:ok, {201, [{"location", "/v1/campaigns/" <> Views.id(@prefix, id)}], view}}
    else
      :tenant_inactive -> {:error, suspended()}
      {:error, error} -> {:error, error}
    end
  end

  # WF-52
  @doc "Prepares the blind indexes of a part of a list audience outside any transaction."
  @spec plan_recipients(Relay.Scope.t(), map()) :: {:ok, [binary()]} | {:error, Relay.Error.t()}
  def plan_recipients(scope, body), do: indexes(scope, {:list, Enum.uniq(body["recipients"])})

  # API-35
  # WF-52
  @doc "Adds a part of a draft list audience inside the request's transaction: how many were added, were already listed and have no subscriber."
  @spec add_recipients(Relay.Id.t(), [binary()]) :: answer()
  def add_recipients(id, bidxs) do
    case listed(Store.get(id), bidxs) do
      {:ok, {added, duplicates, not_found}} ->
        body = %{
          "object" => "campaign_recipients",
          "campaign_id" => Views.id(@prefix, id),
          "added" => added,
          "duplicates" => duplicates,
          "not_found" => not_found,
          "audience_count" => Store.get(id)["audience_count"]
        }

        {:ok, {200, [], body}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp listed(%{"audience_kind" => "topic"}, _bidxs),
    do: {:error, conflict("a topic audience is frozen from its topic")}

  defp listed(%{"id" => id}, bidxs), do: add(id, bidxs)
  defp listed(nil, _bidxs), do: {:error, not_found()}

  defp add(_id, []), do: {:ok, {0, 0, 0}}

  defp add(id, bidxs) do
    recipients = bidxs |> Relay.Subscribers.resolve_indexes() |> Enum.uniq()
    not_found = max(length(bidxs) - length(recipients), 0)
    add_ids(id, recipients, not_found)
  end

  defp add_ids(id, recipients, not_found) do
    ids = Enum.map(recipients, &Plan.member_id(id, &1))
    keys = Enum.map(recipients, &Plan.dedup_key(id, &1))

    case Store.add_members(id, ids, recipients, keys, not_found) do
      {:added, added, duplicates} -> {:ok, {added, duplicates, not_found}}
      {:not_found, _added, _duplicates} -> {:error, not_found()}
      {:not_draft, _added, _duplicates} -> {:error, conflict("the audience is frozen")}
      {:too_large, _added, _duplicates} -> too_large()
    end
  end

  defp too_large do
    field("/recipients", "not_allowed", "a campaign has at most 10000000 recipients")
  end

  # API-35
  # X-14
  @doc "Reads a campaign with its preview and progress in its own scoped transaction."
  @spec get(Relay.Scope.t(), Relay.Id.t()) :: answer()
  def get(scope, id) do
    case Store.in_scope(scope, fn _status -> current_view(id) end) do
      {:ok, {:ok, view}} -> {:ok, {200, [], view}}
      {:ok, {:error, error}} -> {:error, error}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # API-56
  @doc "Lists campaigns newest first, in pages."
  @spec list(Relay.Scope.t(), Relay.Api.Pagination.page(), String.t()) :: answer()
  def list(scope, page, endpoint) do
    position = &{&1["created_at"], &1["id"]}

    read = fn _status ->
      rows = Store.page(page.cursor, page.limit)
      {rows, Map.new(rows, &{&1["id"], view(&1)})}
    end

    with {:ok, {rows, views}} <- unwrap(Store.in_scope(scope, read)),
         render = &Map.fetch!(views, &1["id"]),
         {:ok, body} <- Page.envelope(rows, page, scope, endpoint, render, position) do
      {:ok, {200, [], body}}
    end
  end

  # WF-44
  # API-35
  @doc "Reads what a preparation freezes outside any transaction: the campaign's published workflow and its topic."
  @spec plan_prepare(Relay.Scope.t(), Relay.Id.t()) :: {:ok, planned()} | error()
  def plan_prepare(scope, id) do
    with {:ok, c} <- read(scope, id), do: plan_draft(scope, c)
  end

  defp plan_draft(scope, %{"state" => "draft"} = c) do
    with {:ok, workflow} <- workflow(scope, c["workflow_key"]),
         :ok <- campaign_class(workflow) do
      {:ok, %{id: c["id"], workflow: workflow, topic: c["topic_key"]}}
    end
  end

  defp plan_draft(_scope, c), do: {:ok, %{id: c["id"], workflow: nil, topic: nil}}

  # WF-44
  @doc "Freezes a draft campaign inside the request's transaction and queues its preparation; `202` with its view."
  @spec prepare(Relay.Scope.t(), planned()) :: answer()
  def prepare(_scope, %{workflow: nil}), do: {:error, conflict("the campaign is not a draft")}

  def prepare(scope, %{id: id, workflow: w} = plan) do
    with :ok <- freeze_topic(id, plan.topic) do
      frozen(scope, id, w)
    end
  end

  # WF-52
  # WF-53
  defp freeze_topic(_id, nil), do: :ok

  defp freeze_topic(id, key) do
    case Relay.Topics.recipients(key, @max_audience) do
      {:ok, recipients} -> add_parts(id, Enum.chunk_every(recipients, @part))
      :unknown -> {:error, Relay.Error.new(:topic_not_found, "no topic has this key")}
      :archived -> {:error, Relay.Error.new(:topic_archived, "the topic is archived")}
    end
  end

  defp add_parts(_id, []), do: :ok

  defp add_parts(id, [part | rest]) do
    with {:ok, _counts} <- add_ids(id, part, 0), do: add_parts(id, rest)
  end

  defp frozen(scope, id, w) do
    case Store.prepare(id, w["workflow_id"], w["version_no"], w["message_class"]) do
      :preparing -> queued(PrepareJob.new(job_args(scope, id)), id)
      :not_found -> {:error, not_found()}
      :not_draft -> {:error, conflict("the campaign is not a draft")}
      :deadline_passed -> {:error, conflict("the deadline has passed")}
      :empty -> {:error, conflict("the audience is empty")}
    end
  end

  defp queued(job, id) do
    case Oban.insert(job) do
      {:ok, _job} -> answer(id, 202)
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  @doc "The job arguments of a campaign: its scope and identifier only."
  @spec job_args(Relay.Scope.t(), Relay.Id.t()) :: map()
  def job_args(scope, id),
    do: scope |> Relay.Scope.to_job_args() |> Map.put("campaign_id", Relay.Id.to_string(id))

  # WF-62
  # OP-47
  @doc "Renders the deterministic samples of a prepared campaign outside any transaction, with the digest an approval names."
  @spec samples(Relay.Scope.t(), Relay.Id.t()) :: answer()
  def samples(scope, id) do
    with {:ok, c} <- read(scope, id),
         :ok <- prepared(c),
         {:ok, {digest, entries}} <- sample_set(scope, c) do
      body = %{
        "object" => "campaign_samples",
        "campaign_id" => Views.id(@prefix, id),
        "samples_digest" => Base.encode16(digest, case: :lower),
        "samples" => entries
      }

      {:ok, {200, Previews.headers(), body}}
    end
  end

  defp prepared(%{"state" => state}) when state in ["draft", "preparing"],
    do: {:error, conflict("the campaign is not prepared")}

  defp prepared(_campaign), do: :ok

  defp sample_set(scope, c) do
    read = fn _status -> Store.samples(c["id"], Plan.sample_count()) end

    with {:ok, members} <- unwrap(Store.in_scope(scope, read)),
         {:ok, external} <- unwrap(external_ids(scope, members)),
         {:ok, data} <- open_data(scope, c) do
      entries = Enum.map(members, &sample(scope, c, Map.get(external, &1["recipient_id"]), data))
      {:ok, {:crypto.hash(:sha256, Jason.encode!(entries)), entries}}
    end
  end

  defp external_ids(scope, members),
    do: Relay.Subscribers.external_ids(scope, Enum.map(members, & &1["recipient_id"]))

  defp sample(_scope, _c, nil, _data),
    do: %{"recipient" => nil, "error" => "recipient_not_found", "steps" => []}

  defp sample(scope, c, external_id, data) do
    body = %{"to" => external_id, "data" => data, "version" => c["workflow_version_no"]}

    case Previews.workflow(scope, c["workflow_key"], body, nil) do
      {:ok, {_status, _headers, preview}} ->
        %{"recipient" => external_id, "error" => nil, "steps" => preview["steps"]}

      {:error, %Relay.Error{code: code}} ->
        %{"recipient" => external_id, "error" => Atom.to_string(code), "steps" => []}
    end
  end

  # WF-62
  @doc "Renders the samples again outside any transaction and checks them against the digest the approver saw."
  @spec plan_approve(Relay.Scope.t(), Relay.Id.t(), map()) :: {:ok, digest() | nil} | error()
  def plan_approve(scope, id, body) do
    with {:ok, digest} <- plan_trigger(scope, id),
         :ok <- same(digest, body["samples_digest"]) do
      {:ok, digest}
    end
  end

  defp same(nil, _text), do: :ok

  defp same(digest, text) do
    if Base.encode16(digest, case: :lower) == String.downcase(text || ""),
      do: :ok,
      else: {:error, samples_changed()}
  end

  defp samples_changed do
    message = "the sample renders changed; read the samples again"
    Relay.Error.new(:campaign_samples_changed, message)
  end

  # WF-62
  @doc "Records the approval of the samples inside the request's transaction, audited as `campaign.samples_approved`."
  @spec approve_samples(Relay.Scope.t(), Relay.Id.t(), digest() | nil, Relay.Actor.t()) ::
          answer()
  def approve_samples(_scope, _id, nil, _actor),
    do: {:error, conflict("the campaign is not prepared")}

  def approve_samples(scope, id, digest, actor) do
    record = digest(scope, "campaign.samples_approved", id)

    case Store.approve_samples(id, digest, record, actor) do
      :approved -> ok_view(id)
      :not_prepared -> {:error, conflict("the campaign is not prepared")}
      :not_found -> {:error, not_found()}
    end
  end

  # WF-62
  @doc "Renders the samples of a prepared campaign outside any transaction for its trigger and returns their digest."
  @spec plan_trigger(Relay.Scope.t(), Relay.Id.t()) :: {:ok, digest() | nil} | error()
  def plan_trigger(scope, id) do
    with {:ok, c} <- read(scope, id), do: prepared_digest(scope, c)
  end

  defp prepared_digest(scope, %{"state" => "prepared"} = c) do
    with {:ok, {digest, _entries}} <- sample_set(scope, c), do: {:ok, digest}
  end

  defp prepared_digest(_scope, _c), do: {:ok, nil}

  # WF-44
  # WF-62
  @doc "Triggers a prepared campaign inside the request's transaction, audited as `campaign.triggered`, and queues its first tick; `202` with its view."
  @spec trigger(Relay.Scope.t(), Relay.Id.t(), digest() | nil, Relay.Actor.t()) :: answer()
  def trigger(_scope, _id, nil, _actor), do: {:error, conflict("the campaign is not prepared")}

  def trigger(scope, id, samples_digest, actor) do
    record = digest(scope, "campaign.triggered", id)

    case Store.trigger(id, samples_digest, record, actor) do
      :triggered -> queued(TickJob.new(job_args(scope, id)), id)
      :samples_unapproved -> {:error, approval("approve the sample renders first")}
      :audience_unapproved -> {:error, approval("a tenant administrator approves the audience")}
      :samples_changed -> {:error, samples_changed()}
      :deadline_passed -> {:error, conflict("the deadline has passed")}
      :not_prepared -> {:error, conflict("the campaign is not prepared")}
      :not_found -> {:error, not_found()}
    end
  end

  defp approval(message), do: Relay.Error.new(:campaign_approval_required, message)

  # WF-44
  # T-23 (4)
  @doc "Cancels a campaign at any time before it closes, inside the request's transaction, audited as `campaign.cancelled`; its running stages stop at their next sub-batch."
  @spec cancel(Relay.Scope.t(), Relay.Id.t(), map(), Relay.Actor.t()) :: answer()
  def cancel(scope, id, body, actor) do
    record = digest(scope, "campaign.cancelled", id)

    case Store.cancel(id, body["reason"], record, actor) do
      :cancelled -> ok_view(id)
      :already_closed -> {:error, conflict("the campaign is closed")}
      :not_found -> {:error, not_found()}
    end
  end

  # WF-62
  # OP-37
  @doc "A tenant administrator approves an audience above 1.5 times its expected count, inside the request's transaction, audited as `campaign.audience_approved`."
  @spec approve_audience(Relay.Scope.t(), Relay.Id.t(), map(), Relay.Actor.t()) :: answer()
  def approve_audience(scope, id, body, actor) do
    record = digest(scope, "campaign.audience_approved", id)

    case Store.approve_audience(id, body["reason"], record, actor) do
      :approved -> ok_view(id)
      :not_required -> {:error, conflict("the audience needs no approval")}
      :not_prepared -> {:error, conflict("the campaign is not prepared")}
      :not_found -> {:error, not_found()}
    end
  end

  # OP-47
  @doc "A tenant administrator resumes a paused campaign inside the request's transaction, audited as `campaign.resumed`; a campaign kill switch still in force pauses it again."
  @spec resume(Relay.Scope.t(), Relay.Id.t(), map(), Relay.Actor.t()) :: answer()
  def resume(scope, id, body, actor) do
    record = digest(scope, "campaign.resumed", id)

    case Store.resume(id, body["reason"], record, actor) do
      :resumed -> ok_view(id)
      :not_paused -> {:error, conflict("the campaign is not paused")}
      :not_found -> {:error, not_found()}
    end
  end

  # WF-62
  # OP-47
  @doc "Approves an audience or resumes a campaign for an operator in its own scoped transaction; `action` is `:approve_audience` or `:resume`."
  @spec operator(atom(), Relay.Scope.t(), Relay.Id.t(), map(), Relay.Actor.t()) ::
          {:ok, {pos_integer(), map()}} | error()
  def operator(action, scope, id, body, actor) when action in [:approve_audience, :resume] do
    work = fn _status -> operate(action, scope, id, body, actor) end

    case Store.in_scope(scope, work) do
      {:ok, {:ok, {status, _headers, view}}} -> {:ok, {status, view}}
      {:ok, {:error, error}} -> {:error, error}
      {:error, :tenant_not_found} -> {:error, not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp operate(:approve_audience, scope, id, body, actor),
    do: approve_audience(scope, id, body, actor)

  defp operate(:resume, scope, id, body, actor), do: resume(scope, id, body, actor)

  defp ok_view(id), do: answer(id, 200)

  defp answer(id, status) do
    case current_view(id) do
      {:ok, view} -> {:ok, {status, [], view}}
      {:error, error} -> {:error, error}
    end
  end

  defp current_view(id) do
    case Store.get(id) do
      nil -> {:error, not_found()}
      row -> {:ok, view(row)}
    end
  end

  # X-14
  # T-23 (6)
  @doc "The API view of a campaign row with its preview and progress; read inside the caller's scoped transaction."
  @spec view(map()) :: map()
  def view(c) do
    %{
      "object" => "campaign",
      "id" => Views.id(@prefix, c["id"]),
      "name" => c["name"],
      "workflow" => %{"key" => c["workflow_key"], "version" => c["workflow_version_no"]},
      "message_class" => c["message_class"],
      "state" => c["state"],
      "mode" => Atom.to_string(Relay.Platform.fanout_mode(c["audience_count"])),
      "deadline" => c["deadline"],
      "audience" => audience_view(c),
      "preview" => preview_view(c),
      "approvals" => approvals_view(c),
      "progress" => progress_view(c),
      "pause_rule_id" => c["pause_rule_id"],
      "close_rule_id" => c["close_rule_id"],
      "created_at" => c["created_at"],
      "prepared_at" => c["prepared_at"],
      "triggered_at" => c["triggered_at"],
      "closed_at" => c["closed_at"]
    }
  end

  defp audience_view(c) do
    %{
      "kind" => c["audience_kind"],
      "topic" => c["topic_key"],
      "count" => c["audience_count"],
      "not_found" => c["not_found_count"],
      "expected_count" => c["expected_count"]
    }
  end

  defp preview_view(%{"state" => "draft"}), do: nil

  defp preview_view(c) do
    counts = Store.preview_counts(c["id"])

    %{
      "state" => if(c["state"] == "preparing", do: "pending", else: "ready"),
      "evaluated" => c["evaluated_count"],
      "reachable" => c["reachable_count"],
      "sendable" => by_key(counts, "send"),
      "deferred" => by_key(counts, "defer"),
      "drops" => for(%{"kind" => "drop"} = r <- counts, do: drop(r)),
      "estimate" => c["estimate"]
    }
  end

  defp by_key(counts, kind), do: for(%{"kind" => ^kind} = r <- counts, into: %{}, do: pair(r))

  defp pair(row), do: {row["key"], row["count"]}

  defp drop(row), do: %{"rule_id" => row["key"], "count" => row["count"]}

  defp approvals_view(c) do
    %{
      "samples" => %{
        "approved_at" => c["samples_approved_at"],
        "approved_by" => c["samples_approved_by"]
      },
      "audience" => %{
        "required" => c["audience_approval_required"],
        "approved_at" => c["audience_approved_at"],
        "approved_by" => c["audience_approved_by"]
      }
    }
  end

  defp progress_view(c) do
    %{
      "stage" => c["stage_no"],
      "stage_count" => c["stage_count"],
      "next_stage_at" => c["next_stage_at"],
      "stages" => Enum.map(Store.stages(c["id"]), &stage_view/1),
      "accepted" => c["accepted_count"],
      "rejected" => c["rejected_count"],
      "expired" => c["expired_count"],
      "cancelled" => c["cancelled_count"]
    }
  end

  defp stage_view(s) do
    %{
      "stage" => s["stage_no"],
      "percent" => s["percent"],
      "member_count" => s["member_count"],
      "done_count" => s["done_count"],
      "opened_at" => s["opened_at"]
    }
  end

  @doc "Reads a campaign in its own scoped transaction."
  @spec read(Relay.Scope.t(), Relay.Id.t()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def read(scope, id) do
    case Store.in_scope(scope, fn _status -> Store.get(id) end) do
      {:ok, nil} -> {:error, not_found()}
      {:ok, row} -> {:ok, row}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  @doc "Decrypts a campaign's data outside any transaction."
  @spec open_data(Relay.Scope.t(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def open_data(scope, c) do
    case Relay.Tenancy.decrypt_field(field(scope, c["data_key_id"]), c["data_ct"]) do
      {:ok, plain} -> {:ok, Jason.decode!(Relay.Redacted.expose(plain))}
      {:error, _error} -> {:error, unavailable()}
    end
  end

  defp seal(scope, data) do
    with {:ok, key_id} <- Relay.Tenancy.active_tenant_key(scope, :data),
         {:ok, key} <- Relay.Tenancy.data_key(field(scope, key_id)),
         plain = Jason.encode!(data),
         {:ok, data_ct} <- encrypt(scope, key_id, plain, key) do
      {:ok, %{key_id: key_id, data_ct: data_ct}}
    else
      {:error, _error} -> {:error, unavailable()}
    end
  end

  defp encrypt(scope, key_id, plain, key),
    do: Relay.Tenancy.encrypt_field(field(scope, key_id), plain, data_key: key)

  defp field(scope, key_id) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: nil,
      retention_class: :notification_content,
      table: "campaigns",
      column: "data_ct",
      key_id: key_id
    }
  end

  defp indexes(_scope, {:topic, _key}), do: {:ok, []}
  defp indexes(_scope, {:list, []}), do: {:ok, []}

  defp indexes(scope, {:list, ids}) do
    case Relay.Subscribers.indexes(scope, ids) do
      {:ok, bidxs} -> {:ok, Enum.uniq(bidxs)}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp audience(body) do
    case {body["recipients"], body["topic"]} do
      {nil, nil} -> {:ok, {:list, []}}
      {ids, nil} -> {:ok, {:list, Enum.uniq(ids)}}
      {nil, key} -> {:ok, {:topic, key}}
      _both -> field("/topic", "not_allowed", "name recipients or a topic, not both")
    end
  end

  defp deadline(scope, text) do
    with {:ok, at, _offset} <- DateTime.from_iso8601(text || ""),
         :ok <- Plan.deadline(at, Relay.Clock.business_now(scope)) do
      {:ok, DateTime.truncate(at, :microsecond)}
    else
      {:error, _reason} -> field("/deadline", "invalid_format", "an RFC 3339 time")
      :past -> field("/deadline", "not_allowed", "the deadline has passed")
      :too_far -> field("/deadline", "not_allowed", "at most 31 days ahead")
    end
  end

  defp workflow(scope, key) do
    case Relay.Workflow.resolve_published(scope, key) do
      {:ok, {:ok, workflow}} ->
        {:ok, workflow}

      {:ok, :not_found} ->
        {:error, Relay.Error.new(:workflow_not_found, "no workflow has this key")}

      {:ok, :not_published} ->
        message = "the workflow has no published version"
        {:error, Relay.Error.new(:workflow_not_published, message)}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  defp campaign_class(%{"message_class" => "security"}),
    do: field("/workflow", "not_allowed", "a security workflow is not sent as a campaign")

  defp campaign_class(_workflow), do: :ok

  # API-27
  defp event_data(workflow, data) do
    with {:ok, root} <- Relay.Workflow.event_schema(workflow["event_schema"]),
         {:error, error} <- Schema.validate(root, data) do
      errors = Enum.map(error.details.errors, &%{&1 | pointer: "/data" <> &1.pointer})
      message = "data does not match the event schema"
      {:error, Relay.Error.new(:validation_failed, message, %{errors: errors})}
    else
      _valid_or_no_schema -> :ok
    end
  end

  @doc "The record digest of a campaign action."
  @spec digest(Relay.Scope.t(), String.t(), Relay.Id.t()) :: digest()
  def digest(scope, action, id) do
    environment = Atom.to_string(scope.environment)
    parts = [action, {:bytes, scope.tenant_id}, environment, Relay.Id.to_string(id)]
    :crypto.hash(:sha256, Relay.Canonical.encode!(parts))
  end

  @doc "Whether a campaign state is closed."
  @spec closed?(String.t()) :: boolean()
  def closed?(state), do: state in @closed

  defp unwrap({:ok, value}), do: {:ok, value}
  defp unwrap({:error, _reason}), do: {:error, unavailable()}

  defp conflict(message), do: Relay.Error.new(:resource_conflict, message)

  defp suspended, do: Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})

  defp field(pointer, code, detail) do
    {:error,
     Relay.Error.new(:validation_failed, detail, %{
       errors: [%{pointer: pointer, code: code, detail: detail}]
     })}
  end
end
