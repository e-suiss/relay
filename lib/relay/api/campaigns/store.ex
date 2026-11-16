defmodule Relay.Api.Campaigns.Store do
  @moduledoc """
  Data access of campaigns through the `relay_fn.campaign_*` functions and scoped reads of `relay.campaigns`, `relay.campaign_members`, `relay.campaign_stages` and `relay.campaign_preview_counts`. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @columns "id, name, workflow_key, workflow_id, workflow_version_no, message_class::text AS message_class, audience_kind, topic_key, data_key_id, data_ct, api_client_ref, expected_count, deadline, state, audience_count, not_found_count, prepare_after, evaluated_count, reachable_count, estimate, estimated_duration_s, samples_digest, samples_approved_at, samples_approved_by, audience_approval_required, audience_approved_at, audience_approved_by, stage_count, stage_no, next_stage_at, accepted_count, rejected_count, expired_count, cancelled_count, pause_rule_id, close_rule_id, overrun_reported, prepared_at, triggered_at, closed_at, created_at, updated_at"
  @page_after "SELECT m.id FROM relay.campaign_members m JOIN relay.campaign_stages s ON s.tenant_id = m.tenant_id AND s.environment = m.environment AND s.campaign_id = m.campaign_id WHERE s.id = $1 AND m.id > $2 AND ($3::uuid IS NULL OR m.id < $3::uuid) ORDER BY m.id LIMIT $4"
  @page_from "SELECT m.id FROM relay.campaign_members m JOIN relay.campaign_stages s ON s.tenant_id = m.tenant_id AND s.environment = m.environment AND s.campaign_id = m.campaign_id WHERE s.id = $1 AND ($2::uuid IS NULL OR m.id >= $2::uuid) AND ($3::uuid IS NULL OR m.id < $3::uuid) ORDER BY m.id LIMIT $4"
  @stage_columns "id, campaign_id, stage_no, percent, range_from, range_to, member_count, done_count, fanout_id, opened_at"

  @type digest :: <<_::256>>
  @type id :: Relay.Id.t()
  @type count_row :: {String.t(), String.t(), non_neg_integer()}
  @type position :: {:after | :from, id() | nil}
  @type add_result :: :added | :not_draft | :too_large | :not_found
  @type added :: {add_result(), non_neg_integer(), non_neg_integer()}

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @doc "Rolls the current transaction back with `value`."
  @spec rollback(term()) :: no_return()
  def rollback(value), do: Repo.rollback(value)

  # API-35
  @doc "Records a new draft campaign."
  @spec create(map()) :: :created | :tenant_inactive
  def create(c) do
    [row] =
      Repo.call!("relay_fn.campaign_create", [
        c.id,
        c.name,
        c.workflow_key,
        c.audience_kind,
        c.topic_key,
        c.data_key_id,
        c.data_ct,
        c.api_client_ref,
        c.expected_count,
        c.deadline
      ])

    Repo.code!(row["campaign_create"], [:created, :tenant_inactive])
  end

  # WF-44
  # WF-52
  @doc "Adds members to a draft list campaign; a recipient already in the audience is counted as a duplicate."
  @spec add_members(id(), [id()], [id()], [String.t()], non_neg_integer()) :: added()
  def add_members(campaign_id, ids, recipient_ids, dedup_keys, not_found) do
    [row] =
      Repo.call!("relay_fn.campaign_members_add", [
        campaign_id,
        ids,
        recipient_ids,
        dedup_keys,
        not_found
      ])

    {Repo.code!(row["result"], [:added, :not_draft, :too_large, :not_found]), row["added"],
     row["duplicates"]}
  end

  # WF-44
  @doc "Freezes a draft campaign's audience and workflow version and starts its preparation."
  @spec prepare(Relay.Id.t(), Relay.Id.t(), pos_integer(), String.t()) ::
          :preparing | :not_draft | :deadline_passed | :empty | :not_found
  def prepare(campaign_id, workflow_id, version_no, message_class) do
    params = [campaign_id, workflow_id, version_no, message_class]
    [row] = Repo.call!("relay_fn.campaign_prepare", params)

    Repo.code!(row["campaign_prepare"], [
      :preparing,
      :not_draft,
      :deadline_passed,
      :empty,
      :not_found
    ])
  end

  # X-14
  @doc "Adds the dry evaluation counts of one page of the audience and moves the preparation checkpoint."
  @spec prepare_progress(id(), id(), non_neg_integer(), non_neg_integer(), [count_row()]) ::
          :recorded | :stale | :not_preparing
  def prepare_progress(campaign_id, last_id, evaluated, reachable, counts) do
    {kinds, keys, values} = unzip3(counts)

    [row] =
      Repo.call!("relay_fn.campaign_prepare_progress", [
        campaign_id,
        last_id,
        evaluated,
        reachable,
        kinds,
        keys,
        values
      ])

    Repo.code!(row["campaign_prepare_progress"], [:recorded, :stale, :not_preparing])
  end

  defp unzip3(triples) do
    {Enum.map(triples, &elem(&1, 0)), Enum.map(triples, &elem(&1, 1)),
     Enum.map(triples, &elem(&1, 2))}
  end

  # X-14
  # WF-62
  @doc "Ends a preparation with its cost estimate and duration estimate; emits `campaign.prepared`."
  @spec prepared(Relay.Id.t(), map(), non_neg_integer()) :: :prepared | :not_preparing
  def prepared(campaign_id, estimate, duration_s) do
    [row] = Repo.call!("relay_fn.campaign_prepared", [campaign_id, estimate, duration_s])
    Repo.code!(row["campaign_prepared"], [:prepared, :not_preparing])
  end

  # WF-62
  @doc "Records the approval of a sample render set by its digest, audited."
  @spec approve_samples(Relay.Id.t(), digest(), digest(), Actor.t()) ::
          :approved | :not_prepared | :not_found
  def approve_samples(campaign_id, samples_digest, digest, %Actor{} = actor) do
    params = [campaign_id, samples_digest, digest | Actor.params(actor)]
    [row] = Repo.call!("relay_fn.campaign_approve_samples", params)
    Repo.code!(row["campaign_approve_samples"], [:approved, :not_prepared, :not_found])
  end

  # WF-62
  # OP-47
  @doc "Records a tenant administrator's approval of an audience above 1.5 times its expected count, audited."
  @spec approve_audience(Relay.Id.t(), String.t(), digest(), Actor.t()) ::
          :approved | :not_required | :not_prepared | :not_found
  def approve_audience(campaign_id, reason, digest, %Actor{} = actor) do
    params = [campaign_id, reason, digest | Actor.params(actor)]
    [row] = Repo.call!("relay_fn.campaign_approve_audience", params)

    Repo.code!(row["campaign_approve_audience"], [
      :approved,
      :not_required,
      :not_prepared,
      :not_found
    ])
  end

  # WF-44
  # WF-62
  @doc "Triggers a prepared campaign whose samples are approved with this digest: writes its stages and audits the trigger."
  @spec trigger(Relay.Id.t(), digest(), digest(), Actor.t()) ::
          :triggered
          | :samples_unapproved
          | :samples_changed
          | :audience_unapproved
          | :deadline_passed
          | :not_prepared
          | :not_found
  def trigger(campaign_id, samples_digest, digest, %Actor{} = actor) do
    params = [campaign_id, samples_digest, digest | Actor.params(actor)]
    [row] = Repo.call!("relay_fn.campaign_trigger", params)

    Repo.code!(row["campaign_trigger"], [
      :triggered,
      :samples_unapproved,
      :samples_changed,
      :audience_unapproved,
      :deadline_passed,
      :not_prepared,
      :not_found
    ])
  end

  # T-23 (1)
  @doc "The keyset bounds of a stage's slices of `slice_size` members: the stage's lower bound, the first member of every later slice and the stage's upper bound (`nil` = unbounded)."
  @spec stage_bounds(Relay.Id.t(), pos_integer()) :: [Relay.Id.t() | nil] | nil
  def stage_bounds(stage_id, slice_size) do
    [row] = Repo.call!("relay_fn.campaign_stage_bounds", [stage_id, slice_size])
    row["campaign_stage_bounds"]
  end

  # WF-62
  @doc "Records the fan-out of an opened stage."
  @spec stage_open(Relay.Id.t(), pos_integer(), Relay.Id.t()) ::
          :opened | :already_open | :not_running | :not_found
  def stage_open(campaign_id, stage_no, fanout_id) do
    [row] = Repo.call!("relay_fn.campaign_stage_open", [campaign_id, stage_no, fanout_id])
    Repo.code!(row["campaign_stage_open"], [:opened, :already_open, :not_running, :not_found])
  end

  # WF-62
  @doc "Sets when the next stage may open, unless it is already set."
  @spec stage_wait(Relay.Id.t(), DateTime.t()) :: :waiting | :not_running
  def stage_wait(campaign_id, until) do
    [row] = Repo.call!("relay_fn.campaign_stage_wait", [campaign_id, until])
    Repo.code!(row["campaign_stage_wait"], [:waiting, :not_running])
  end

  # WF-44
  @doc "Marks a pending member accepted with its notification or rejected with its error code."
  @spec mark(id(), id(), :accepted | :rejected, id() | nil, String.t() | nil) ::
          :marked | :not_pending | :not_running | :not_found
  def mark(campaign_id, member_id, state, notification_id, code) do
    params = [campaign_id, member_id, Atom.to_string(state), notification_id, code]
    [row] = Repo.call!("relay_fn.campaign_member_mark", params)
    Repo.code!(row["campaign_member_mark"], [:marked, :not_pending, :not_running, :not_found])
  end

  # WF-62
  # TN-40
  @doc "Pauses a running campaign under a rule; emits `campaign.paused`."
  @spec pause(Relay.Id.t(), String.t()) :: :paused | :not_running
  def pause(campaign_id, rule_id) do
    [row] = Repo.call!("relay_fn.campaign_pause", [campaign_id, rule_id])
    Repo.code!(row["campaign_pause"], [:paused, :not_running])
  end

  # OP-47
  @doc "Resumes a paused campaign, audited; emits `campaign.resumed`."
  @spec resume(Relay.Id.t(), String.t(), digest(), Actor.t()) ::
          :resumed | :not_paused | :not_found
  def resume(campaign_id, reason, digest, %Actor{} = actor) do
    params = [campaign_id, reason, digest | Actor.params(actor)]
    [row] = Repo.call!("relay_fn.campaign_resume", params)
    Repo.code!(row["campaign_resume"], [:resumed, :not_paused, :not_found])
  end

  # WF-34
  # T-23 (3)
  @doc "Closes a running or paused campaign: `campaign.completed` once every member is done, `campaign.deadline_expired` at the deadline, when the members left are counted `expired`."
  @spec close(Relay.Id.t(), String.t()) ::
          {:closed | :already_closed | :not_running | :not_done | :not_found, String.t() | nil}
  def close(campaign_id, rule_id) do
    [row] = Repo.call!("relay_fn.campaign_close", [campaign_id, rule_id])

    {Repo.code!(row["result"], [:closed, :already_closed, :not_running, :not_done, :not_found]),
     row["state"]}
  end

  # WF-44
  @doc "Cancels a campaign that is not closed, audited; its waiting send jobs are cancelled and `campaign.cancelled` is emitted."
  @spec cancel(Relay.Id.t(), String.t(), digest(), Actor.t()) ::
          :cancelled | :already_closed | :not_found
  def cancel(campaign_id, reason, digest, %Actor{} = actor) do
    params = [campaign_id, reason, digest | Actor.params(actor)]
    [row] = Repo.call!("relay_fn.campaign_cancel", params)
    Repo.code!(row["campaign_cancel"], [:cancelled, :already_closed, :not_found])
  end

  # OP-37
  @doc "Marks the campaign's overrun as reported once."
  @spec overrun(Relay.Id.t()) :: :reported | :already_reported
  def overrun(campaign_id) do
    [row] = Repo.call!("relay_fn.campaign_overrun", [campaign_id])
    Repo.code!(row["campaign_overrun"], [:reported, :already_reported])
  end

  # WF-62
  @doc "The delivery counts by channel of the campaign's most recently accepted `limit` members: sent, delivered, permanent failures and complaints."
  @spec rates(Relay.Id.t(), pos_integer()) :: [map()]
  def rates(campaign_id, limit), do: Repo.call!("relay_fn.campaign_rates", [campaign_id, limit])

  @doc "Reads a campaign, or `nil`."
  @spec get(Relay.Id.t()) :: map() | nil
  def get(id) do
    case all("SELECT #{@columns} FROM relay.campaigns WHERE id = $1", [id]) do
      [row] -> row
      [] -> nil
    end
  end

  # API-56
  @doc "A page of campaigns newest first from a decoded cursor; at most `limit + 1` rows come back."
  @spec page(map() | nil, pos_integer()) :: [map()]
  def page(nil, limit) do
    all(
      "SELECT #{@columns} FROM relay.campaigns ORDER BY created_at DESC, id DESC LIMIT $1",
      [limit + 1]
    )
  end

  def page(%{direction: :after, sort_ts_us: ts, id: id}, limit) do
    all(
      "SELECT #{@columns} FROM relay.campaigns WHERE (created_at, id) < ($1, $2) ORDER BY created_at DESC, id DESC LIMIT $3",
      [DateTime.from_unix!(ts, :microsecond), id, limit + 1]
    )
  end

  def page(%{direction: :before, sort_ts_us: ts, id: id}, limit) do
    "SELECT #{@columns} FROM relay.campaigns WHERE (created_at, id) > ($1, $2) ORDER BY created_at, id LIMIT $3"
    |> all([DateTime.from_unix!(ts, :microsecond), id, limit + 1])
    |> Enum.reverse()
  end

  @doc "The stages of a campaign in order."
  @spec stages(Relay.Id.t()) :: [map()]
  def stages(campaign_id) do
    all(
      "SELECT #{@stage_columns} FROM relay.campaign_stages WHERE campaign_id = $1 ORDER BY stage_no",
      [campaign_id]
    )
  end

  @doc "Reads a stage by its identifier, or `nil`."
  @spec stage(Relay.Id.t()) :: map() | nil
  def stage(stage_id) do
    case all("SELECT #{@stage_columns} FROM relay.campaign_stages WHERE id = $1", [stage_id]) do
      [row] -> row
      [] -> nil
    end
  end

  # X-14
  @doc "The dry evaluation counts of a campaign: `{kind, key, count}` rows."
  @spec preview_counts(Relay.Id.t()) :: [map()]
  def preview_counts(campaign_id) do
    all(
      "SELECT kind, key, count FROM relay.campaign_preview_counts WHERE campaign_id = $1 ORDER BY kind, count DESC, key",
      [campaign_id]
    )
  end

  # T-23 (1)
  @doc "At most `limit` members of a campaign in identifier order after `after` (`nil` = from the first)."
  @spec members_after(Relay.Id.t(), Relay.Id.t() | nil, pos_integer()) :: [map()]
  def members_after(campaign_id, nil, limit) do
    all(
      "SELECT id, recipient_id FROM relay.campaign_members WHERE campaign_id = $1 ORDER BY id LIMIT $2",
      [campaign_id, limit]
    )
  end

  def members_after(campaign_id, after_id, limit) do
    all(
      "SELECT id, recipient_id FROM relay.campaign_members WHERE campaign_id = $1 AND id > $2 ORDER BY id LIMIT $3",
      [campaign_id, after_id, limit]
    )
  end

  # WF-44
  @doc "The pending members of a campaign from `from` to `to`, both included."
  @spec pending_members(Relay.Id.t(), Relay.Id.t(), Relay.Id.t()) :: [map()]
  def pending_members(campaign_id, from, to) do
    all(
      "SELECT id, recipient_id, dedup_key FROM relay.campaign_members WHERE campaign_id = $1 AND id >= $2 AND id <= $3 AND state = 'pending' ORDER BY id",
      [campaign_id, from, to]
    )
  end

  # T-23 (1)
  @doc "At most `limit` member identifiers of a stage's campaign in identifier order from `position` and below `range_to` (`nil` = unbounded)."
  @spec stage_page(id(), position(), id() | nil, pos_integer()) :: [id()]
  def stage_page(stage_id, {:after, id}, range_to, limit),
    do: ids(@page_after, [stage_id, id, range_to, limit])

  def stage_page(stage_id, {:from, id}, range_to, limit),
    do: ids(@page_from, [stage_id, id, range_to, limit])

  defp ids(sql, params), do: for(row <- all(sql, params), do: row["id"])

  # WF-62
  @doc "The first `count` members of a campaign in identifier order: its deterministic samples."
  @spec samples(Relay.Id.t(), pos_integer()) :: [map()]
  def samples(campaign_id, count) do
    all(
      "SELECT id, recipient_id FROM relay.campaign_members WHERE campaign_id = $1 ORDER BY id LIMIT $2",
      [campaign_id, count]
    )
  end

  defp all(sql, params) do
    %Postgrex.Result{columns: columns, rows: rows} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
