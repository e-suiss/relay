defmodule Relay.Agents.Live do
  @moduledoc """
  Decision requests on the running send path: the outbound side of a waitpoint (AG-25, AG-27, AG-28, AG-63, E-15). It is the invitation sink of `Relay.Agents` (`config :relay, Relay.Agents, invitation_sink: Relay.Agents.Live`) and the content step of deliveries without a template (`config :relay, Relay.Templates.Live, planless: Relay.Agents.Live`).

  An invitation becomes a notification of class `action_required` about its waitpoint, with one delivery per surface it reaches (`Relay.Agents.Live.Surfaces`): e-mail, SMS, every permitted device and, when the invitation carries it, the inbox record. The sink only queues a job inside the transaction that made the invitation; the job opens the notification, its deliveries and their send jobs in one transaction and calls nothing outside. Every delivery then takes the ordinary path: the policy lattice decides it, its content is produced here and the channel step hands it to its provider with fallback, so a policy outcome is a recorded decision. The request goes to all the responder's devices and channels unless the sender's surface policy orders them, and to every responder of the set, so a guardian request reaches all guardians (AG-28, AG-62).

  The content is produced on the server from the waitpoint's typed fields (`Relay.Agents.Live.Request`, AG-29); the sender type is shown on every surface (AG-34); a push is only an invitation with neutral lock screen text (AG-33, CH-67); an approval-type request, one of profile `guardian_approval` or one that carries the deep link to the Access approval surface, has that link as its only action and no response link (AG-32, IN-6, E-16). Relay carries the invitation; the decision and the client notification of the approval stay with Access (E-15).

  A response token is minted only when a delivery of a human channel is handed to its provider, so every send and resend has a token of its own, and it is written only into that message: nothing here writes to the waiter's mailbox, an outbox event or an API view (INV-33, AG-30, AG-31, E-71). The link is the configured `response_link` prefix followed by the token (`config :relay, Relay.Agents.Live, response_link: "https://…#"`, with `response_token: Module` naming who mints); without a prefix or a token the message carries no link.

  An invitation is settled from its deliveries (`Relay.Agents.Live.Settle`): delivered once one reached a surface, unreachable when none can, which lets the next surface step run without waiting. An invitation of a responder that is no active subscriber, or that reaches no surface, is unreachable at once; nothing is lost silently.

  When the waitpoint is resolved, expired or cancelled, no invitation goes out any more: a delivery not yet sent is cancelled, also one whose content is asked for after the close, and the copies already delivered are told that the request no longer awaits a response, the inbox item by an update of the same item and a device by a passive push that replaces the request (AG-35, AG-19, INV-35). An expired request's inbox item ends with its own expiry.
  """

  use Boundary,
    top_level?: true,
    deps: [
      Relay,
      Relay.Agents,
      Relay.Delivery,
      Relay.Devices,
      Relay.Ingest,
      Relay.Platform,
      Relay.Subscribers,
      Relay.Templates,
      Relay.Tenancy,
      Relay.Tenancy.KillSwitch
    ],
    exports: []

  alias Relay.Agents.Live.Close
  alias Relay.Agents.Live.Invite
  alias Relay.Agents.Live.Request
  alias Relay.Agents.Live.Settle
  alias Relay.Agents.Live.Store
  alias Relay.Agents.Live.Surfaces
  alias Relay.Scope
  alias Relay.Tenancy.KillSwitch

  @invitation "waitpoint-invitation:"
  @closed "waitpoint-closed:"
  @rule "waitpoint.invitation_cancelled"
  @actor %Relay.Actor{kind: :system, ref: "relay:waitpoint_requests", on_behalf_of_ref: "relay"}
  @waiting ["open", "stalled"]
  @ended ["resolved", "expired", "cancelled"]
  @human ["email", "sms", "push", "web_push"]
  @channels %{
    "email" => :email,
    "sms" => :sms,
    "push" => :push,
    "web_push" => :web_push,
    "in_app" => :in_app
  }
  @closed_copy_s 86_400
  @settle_in_s 2

  @type content ::
          {:rendered, binary()}
          | :done
          | :foreign
          | {:failed, {atom(), map()}}
          | {:error, {:input_unavailable, atom()}}

  # AG-63
  # T-15
  @doc "The invitation sink of `Relay.Agents`: queues the job of every requested invitation inside the transaction that announced it."
  @spec waitpoint_invitations(Scope.t(), Relay.Id.t(), [map()]) :: :ok
  def waitpoint_invitations(%Scope{} = scope, _waitpoint_id, invitations) do
    Enum.each(invitations, fn %{"id" => id} ->
      queue!(Invite.new(args(scope, "invitation_id", id)))
    end)
  end

  # AG-35
  # AG-19
  @doc "The closing job of a waitpoint that was resolved, expired or cancelled, derived from its outbox event inside the dispatch transaction; `waitpoint_id` is the identifier as text."
  @spec waitpoint_closed_jobs(Scope.t(), String.t()) :: [Ecto.Changeset.t()]
  def waitpoint_closed_jobs(%Scope{} = scope, waitpoint_id) when is_binary(waitpoint_id),
    do: [Close.new(Map.put(Scope.to_job_args(scope), "waitpoint_id", waitpoint_id))]

  defp args(scope, name, id),
    do: scope |> Scope.to_job_args() |> Map.put(name, Relay.Id.to_string(id))

  defp queue!(changeset) do
    case Oban.insert(changeset) do
      {:ok, _job} -> :ok
      {:error, reason} -> raise ArgumentError, "invitation job not queued: #{inspect(reason)}"
    end
  end

  # AG-28
  # AG-63
  # AG-12
  @doc "Delivers an invitation: opens its notification with a delivery for every surface it reaches and their send jobs in one transaction, or settles it as unreachable when its responder is no active subscriber or it reaches no surface. An invitation that is settled, or whose waitpoint is closed, opens nothing."
  @spec invite(Scope.t(), Relay.Id.t()) :: :ok | {:error, term()}
  def invite(%Scope{} = scope, invitation_id) do
    case Store.in_scope(scope, fn _status -> planned(invitation_id) end) do
      {:ok, :done} -> :ok
      {:ok, :unreachable} -> unreachable(scope, invitation_id)
      {:ok, {:open, plan}} -> open(scope, plan)
      {:error, reason} -> {:error, reason}
    end
  end

  defp unreachable(scope, invitation_id) do
    case Relay.Agents.settle_invitation(scope, invitation_id, :unreachable) do
      {:ok, _settled} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp planned(invitation_id) do
    with %{"state" => "requested"} = invitation <- Relay.Agents.invitation(invitation_id),
         %{state: state} = waitpoint when state in @waiting <-
           Relay.Agents.read_waitpoint_in(invitation["waitpoint_id"]) do
      targets(invitation, waitpoint)
    else
      _settled_or_closed -> :done
    end
  end

  defp targets(%{"recipient_kind" => "subscriber"} = invitation, waitpoint) do
    recipient_id = invitation["recipient_id"]

    case Relay.Subscribers.row(recipient_id) do
      %{"state" => "active", "suspended_at" => nil} = row ->
        devices = Relay.Devices.current(recipient_id)

        case Surfaces.select(invitation["surfaces"], invitation["inbox"], row, devices) do
          [] -> :unreachable
          targets -> {:open, %{invitation: invitation, waitpoint: waitpoint, targets: targets}}
        end

      _gone_or_suspended ->
        :unreachable
    end
  end

  defp targets(_agent, _waitpoint), do: :unreachable

  defp open(scope, %{invitation: invitation} = plan) do
    case Store.in_scope(scope, fn _status -> accept(scope, plan) end) do
      {:ok, :opened} -> after_open(scope, plan)
      {:ok, :duplicate} -> :ok
      {:ok, :gone} -> unreachable(scope, invitation["id"])
      {:error, reason} -> {:error, reason}
    end
  end

  # AG-63
  defp after_open(scope, %{invitation: %{"source" => "surface", "id" => id}, targets: targets}) do
    if Enum.any?(targets, &Surfaces.interrupting?/1), do: :ok, else: unreachable(scope, id)
  end

  defp after_open(_scope, _plan), do: :ok

  # E-15
  # AG-27
  # AG-34
  defp accept(scope, %{invitation: invitation, waitpoint: waitpoint, targets: targets}) do
    recipient_id = invitation["recipient_id"]

    notification = %{
      id: Relay.Id.generate(),
      recipient_id: recipient_id,
      dedup_key: @invitation <> Relay.Id.to_string(invitation["id"]),
      message_class: :action_required,
      sender_type: sender(waitpoint),
      subject_type: "waitpoint",
      subject_id: Relay.Id.to_string(waitpoint.id),
      expires_at: waitpoint.expires_at
    }

    case Relay.Ingest.notification_accept(notification) do
      {:created, id} ->
        Enum.each(targets, &deliver!(scope, id, recipient_id, &1))
        settle = args(scope, "invitation_id", invitation["id"])
        :ok = queue!(Settle.new(settle, schedule_in: @settle_in_s))
        :opened

      {:duplicate, _id} ->
        :duplicate

      {_gone, _id} ->
        :gone
    end
  end

  # AG-34
  defp sender(%{waiter_kind: "agent"}), do: :agent
  defp sender(_api_client), do: :system

  defp deliver!(scope, notification_id, recipient_id, target) do
    delivery = %{
      id: Relay.Id.generate(),
      channel: target.channel,
      target_kind: target_kind(target.channel),
      target_id: target.device_id,
      target_key: target_key(target, recipient_id),
      decision: :send,
      provider: target.provider
    }

    case Relay.Ingest.delivery_open(notification_id, delivery) do
      {:opened, id} -> enqueue!(scope, notification_id, id)
      {:exists, _id} -> :ok
      {other, _id} -> Store.rollback({:delivery_not_opened, other})
    end
  end

  defp target_kind(:in_app), do: :inbox
  defp target_kind(channel) when channel in [:push, :web_push], do: :device
  defp target_kind(_address), do: :address

  defp target_key(%{channel: channel, device_id: device_id}, recipient_id) do
    device = if device_id, do: [{:bytes, device_id}], else: []
    fields = ["target", Atom.to_string(channel), {:bytes, recipient_id}] ++ device
    :crypto.hash(:sha256, Relay.Canonical.encode!(fields))
  end

  # T-15
  # TN-40 (1)
  defp enqueue!(scope, notification_id, delivery_id) do
    case KillSwitch.at_acceptance(delivery_id) do
      {:paused, _rule_id} ->
        :ok

      _allow_or_hold ->
        job = %{
          id: Relay.Id.generate(),
          lane: Relay.Platform.lane(:action_required),
          worker: Relay.Delivery.send_worker(),
          args:
            scope
            |> Scope.to_job_args()
            |> Map.merge(%{
              "notification_id" => Relay.Id.to_string(notification_id),
              "delivery_id" => Relay.Id.to_string(delivery_id)
            }),
          ref_kind: "delivery",
          ref_id: delivery_id,
          priority: Relay.Platform.job_priority(:delivery, 1, :normal),
          scheduled_at: nil
        }

        case Relay.Platform.enqueue_job(job) do
          {:ok, _queued} -> :ok
          {:error, error} -> Store.rollback({:job_not_queued, error})
        end
    end
  end

  # AG-63
  # INV-35
  @doc "Settles a requested invitation from its deliveries: `:settled` as delivered once one of them reached a surface, or as unreachable once all of them ended without reaching one; `{:pending, seconds}` with the time since the invitation while they are on their way; `:done` for an invitation that is settled already. A surface step counts only its interrupting deliveries, since its inbox record is never ordered."
  @spec settle(Scope.t(), Relay.Id.t()) ::
          {:ok, :settled | :done | {:pending, non_neg_integer()}} | {:error, term()}
  def settle(%Scope{} = scope, invitation_id) do
    read = fn _status ->
      case Relay.Agents.invitation(invitation_id) do
        %{"state" => "requested"} = invitation ->
          {invitation, Store.invitation_copies(invitation_id, @invitation)}

        _settled_or_gone ->
          :done
      end
    end

    case Store.in_scope(scope, read) do
      {:ok, :done} -> {:ok, :done}
      {:ok, {invitation, copies}} -> outcome(scope, invitation, counted(invitation, copies))
      {:error, reason} -> {:error, reason}
    end
  end

  defp counted(%{"source" => "surface"}, copies),
    do: Enum.reject(copies, &(&1["channel"] == "in_app"))

  defp counted(_invitation, copies), do: copies

  defp outcome(scope, invitation, copies) do
    cond do
      Enum.any?(copies, &reached?/1) ->
        report(scope, invitation, :delivered)

      Enum.all?(copies, &(&1["failure_kind"] != nil)) ->
        report(scope, invitation, :unreachable)

      true ->
        waited = DateTime.diff(Relay.Clock.utc_now(), invitation["invited_at"])
        {:ok, {:pending, max(waited, 0)}}
    end
  end

  defp report(scope, invitation, outcome) do
    case Relay.Agents.settle_invitation(scope, invitation["id"], outcome) do
      {:ok, _settled} -> {:ok, :settled}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reached?(%{"delivery_rank" => rank, "failure_kind" => nil}), do: rank >= 1
  defp reached?(_copy), do: false

  # AG-29
  # AG-30
  # AG-63
  # INV-33
  @doc "The content of a delivery without a template, for `Relay.Templates.Live`: `{:rendered, content}` for a copy of a decision request, `:foreign` for a delivery that is none, `:done` for one that is gone or was cancelled here because its waitpoint closed before it was sent, `{:failed, {reason, detail}}` when the render fails and `{:error, {:input_unavailable, input}}` when an input cannot be read. With `mode` `:verify`, the content of a channel attempt, the copy of a human channel carries a response link with a token minted for it."
  @spec content(Scope.t(), Relay.Id.t(), :once | :verify) :: content()
  def content(%Scope{} = scope, delivery_id, mode) do
    read = fn _status ->
      case Store.delivery(delivery_id) do
        nil ->
          :done

        %{"subject_type" => "waitpoint", "event_id" => nil, "subject_id" => text} = delivery ->
          {delivery, waitpoint(text)}

        _other ->
          :foreign
      end
    end

    case Store.in_scope(scope, read) do
      {:ok, {delivery, %{} = waitpoint}} -> copy(scope, delivery, waitpoint, mode)
      {:ok, {_delivery, nil}} -> :foreign
      {:ok, other} -> other
      {:error, _reason} -> {:error, {:input_unavailable, :waitpoint}}
    end
  end

  defp waitpoint(text) do
    case Relay.Id.parse(text) do
      {:ok, id} -> Relay.Agents.read_waitpoint_in(id)
      {:error, _error} -> nil
    end
  end

  # AG-35
  defp copy(_scope, %{"dedup_key" => @closed <> _waitpoint} = delivery, waitpoint, _mode),
    do: render(delivery, waitpoint, :closed, %{})

  defp copy(scope, delivery, %{state: state} = waitpoint, mode) when state in @waiting do
    opened = opened(scope, waitpoint)
    link = response_link(scope, delivery, waitpoint, opened, mode)
    render(delivery, waitpoint, :invitation, Map.put(opened, :response_link, link))
  end

  # AG-63
  # AG-19
  defp copy(scope, %{"id" => delivery_id}, _closed_waitpoint, _mode) do
    case cancel(scope, delivery_id) do
      :ok -> :done
      {:error, _reason} -> {:error, {:input_unavailable, :waitpoint}}
    end
  end

  # INV-35
  defp cancel(scope, delivery_id) do
    digest = Relay.Agents.agent_digest(scope, @rule, Relay.Id.to_string(delivery_id))

    case Relay.Delivery.cancel_delivery(scope, delivery_id, @rule, digest, @actor) do
      {:ok, _cancelled_or_terminal} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # OP-24
  # AG-32
  defp opened(scope, waitpoint) do
    envelope =
      with {:ok, text} <- unsealed(scope, waitpoint, "content_ct", waitpoint.content_ct),
           {:ok, %{} = fields} <- Jason.decode(text) do
        fields
      else
        _absent_or_unreadable -> %{}
      end

    claim =
      case unsealed(scope, waitpoint, "claim_text_ct", waitpoint.claim_text_ct) do
        {:ok, text} -> text
        :absent -> nil
      end

    link = envelope["access_link"]

    %{
      content: Map.get(envelope, "content", %{}),
      claim: claim,
      access_link: link,
      approval: waitpoint.profile == "guardian_approval" or is_binary(link)
    }
  end

  defp unsealed(_scope, _waitpoint, _column, nil), do: :absent

  defp unsealed(scope, waitpoint, column, ct) do
    field = %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: nil,
      retention_class: :notification_content,
      table: "waitpoints",
      column: column,
      key_id: waitpoint.field_key_id
    }

    case Relay.Tenancy.decrypt_field(field, ct) do
      {:ok, plain} -> {:ok, Relay.Redacted.expose(plain)}
      {:error, _error} -> :absent
    end
  end

  # INV-33
  # AG-30
  # AG-31
  defp response_link(scope, %{"channel" => channel} = delivery, waitpoint, opened, :verify)
       when channel in @human do
    with %{approval: false} <- opened,
         prefix when is_binary(prefix) <- setting(:response_link),
         minter = setting(:response_token) || Relay.Agents,
         {:ok, token} when is_binary(token) <-
           minter.mint_response_token(scope, waitpoint.id, delivery["recipient_id"]) do
      prefix <> URI.encode_www_form(token)
    else
      _no_link -> nil
    end
  end

  defp response_link(_scope, _delivery, _waitpoint, _opened, _mode), do: nil

  defp setting(name), do: Application.get_env(:relay, __MODULE__, [])[name]

  # AG-29
  # AG-34
  defp render(delivery, waitpoint, copy, opened) do
    channel = Map.fetch!(@channels, delivery["channel"])

    built =
      Request.build(%{
        channel: channel,
        copy: copy,
        locale: delivery["locale"],
        interaction: waitpoint.kind,
        approval: Map.get(opened, :approval, false),
        sender_type: delivery["sender_type"],
        waitpoint: Relay.Id.to_string(waitpoint.id),
        state: waitpoint.state,
        content: Map.get(opened, :content, %{}),
        claim: Map.get(opened, :claim),
        access_link: Map.get(opened, :access_link),
        response_link: Map.get(opened, :response_link)
      })

    input = %{
      channel: channel,
      cell: built.cell,
      locale: built.locale,
      time_zone: "Etc/UTC",
      data: built.data,
      links: built.links,
      sensitivity: :sensitive,
      message_class: "action_required"
    }

    case Relay.Templates.render_cell(input) do
      {:ok, rendered} -> {:rendered, document(channel, rendered.content, built)}
      {:error, reason, detail} -> {:failed, {reason, detail}}
    end
  end

  # AG-35
  defp document(:in_app, content, built) do
    case Jason.decode(content) do
      {:ok, %{"output" => %{} = output} = document} ->
        output = Map.merge(output, %{"data" => built.rows, "group_key" => built.group_key})
        Jason.encode!(%{document | "output" => output})

      _other ->
        content
    end
  end

  defp document(_channel, content, _built), do: content

  # AG-35
  # AG-19
  # INV-35
  @doc "Follows a waitpoint that was resolved, expired or cancelled: cancels the deliveries of its invitations that were not sent and opens, once per responder, the copy that tells the surfaces a request reached that it no longer awaits a response: an update of the inbox item, unless the request expired, and a passive push to every device a push reached. A waitpoint that still waits is left alone."
  @spec close(Scope.t(), Relay.Id.t()) :: :ok | {:error, term()}
  def close(%Scope{} = scope, waitpoint_id) do
    read = fn _status ->
      case Relay.Agents.read_waitpoint_in(waitpoint_id) do
        %{state: state} = waitpoint when state in @ended ->
          {waitpoint, Store.waitpoint_copies(waitpoint_id, @invitation)}

        _waiting_or_gone ->
          :waiting
      end
    end

    case Store.in_scope(scope, read) do
      {:ok, :waiting} -> :ok
      {:ok, {waitpoint, copies}} -> closed(scope, waitpoint, copies)
      {:error, reason} -> {:error, reason}
    end
  end

  defp closed(scope, waitpoint, copies) do
    {reached, rest} = Enum.split_with(copies, &reached?/1)
    pending = for %{"failure_kind" => nil, "id" => id} <- rest, do: id

    expires_at = DateTime.add(Relay.Clock.business_now(scope), @closed_copy_s, :second)

    with :ok <- cancel_all(scope, pending) do
      write = fn _status -> announce(scope, waitpoint, reached, expires_at) end

      case Store.in_scope(scope, write) do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp cancel_all(scope, delivery_ids) do
    Enum.reduce_while(delivery_ids, :ok, fn id, :ok ->
      case cancel(scope, id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp announce(scope, waitpoint, reached, expires_at) do
    reached
    |> Enum.group_by(& &1["recipient_id"])
    |> Enum.each(fn {recipient_id, copies} ->
      case closing_targets(waitpoint, copies) do
        [] -> :ok
        targets -> closing(scope, {waitpoint, expires_at}, recipient_id, targets)
      end
    end)
  end

  defp closing_targets(waitpoint, copies) do
    inbox? = waitpoint.state != "expired" and Enum.any?(copies, &(&1["channel"] == "in_app"))

    devices =
      for %{"channel" => channel, "target_id" => <<_::128>> = id} = copy <- copies,
          channel in ["push", "web_push"],
          uniq: true,
          do: %{channel: @channels[channel], device_id: id, provider: copy["provider"]}

    if inbox?, do: [%{channel: :in_app, device_id: nil, provider: nil} | devices], else: devices
  end

  defp closing(scope, {waitpoint, expires_at}, recipient_id, targets) do
    text = Relay.Id.to_string(waitpoint.id)

    notification = %{
      id: Relay.Id.generate(),
      recipient_id: recipient_id,
      dedup_key: @closed <> text,
      message_class: :action_required,
      sender_type: :system,
      subject_type: "waitpoint",
      subject_id: text,
      expires_at: expires_at
    }

    case Relay.Ingest.notification_accept(notification) do
      {:created, id} -> Enum.each(targets, &deliver!(scope, id, recipient_id, &1))
      {_duplicate_or_gone, _id} -> :ok
    end
  end
end
