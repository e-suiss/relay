defmodule Relay.Audit.Checkpointer do
  @moduledoc """
  The `audit_checkpoint` singleton task. Each step reads audit rows committed below the xid8 watermark, appends their Merkle leaves under the fencing token and commits, then (outside any transaction) signs a C2SP checkpoint of the new tree with the Ed25519 key in the key store, records it, publishes it to every configured target and records each outcome. When nothing arrived for a minute it signs a heartbeat of the same tree. The tree is sharded per UTC year (`<host>/relay/audit/<year>`) and the signing key name is the log origin.

  Configuration under `config :relay, Relay.Audit`: `:log_host` (installation host name), `:checkpoint_key` (PKCS#11 label of the Ed25519 key) and `:publishers` (see `Relay.Audit.Checkpointer.Publisher`).

  Telemetry: `[:relay, :audit, :checkpoint]`, `[:relay, :audit, :overdue]` (security event: a record waited longer than the declared interval), `[:relay, :audit, :unpublished]` (no target accepted the checkpoint).
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Audit, Relay.Platform.Maintenance, Relay.Platform.Leadership],
    exports: []

  @behaviour Relay.Platform.Leadership

  require Logger

  alias Relay.Audit.Checkpointer.Publisher
  alias Relay.Audit.Checkpointer.State
  alias Relay.Platform.Maintenance.EscapeHatch

  @page 1_000
  @max_page 64_000
  @rebuild_page 10_000

  # OP-63
  # TN-46
  # INV-55
  @impl Relay.Platform.Leadership
  @doc "Runs one integration and signing step."
  @spec run(Relay.Platform.Leadership.context()) :: Relay.Platform.Leadership.step()
  def run(%{fencing_token: token, state: saved}) do
    config = config()
    now = Relay.Clock.utc_now()
    origin = State.origin(Keyword.fetch!(config, :log_host), now.year)

    state =
      case State.from_json(saved) do
        {:ok, state} -> State.rotate(state, origin)
        :error -> State.new(origin)
      end

    with {:ok, state} <- integrate(state, token, now, @page),
         {:ok, state} <- sign(state, token, config) do
      {:ok, State.to_json(state), div(State.interval_ms(), 2)}
    end
  end

  defp integrate(state, token, now, limit) do
    case EscapeHatch.audit_pending(state.watermark, limit) do
      {:ok, [], _upper} -> {:ok, state}
      {:ok, rows, upper} -> select(state, rows, upper, token, now, limit)
      error -> error
    end
  end

  defp select(state, rows, upper, token, now, limit) do
    case State.select(rows, limit, String.to_integer(upper)) do
      :grow when limit < @max_page ->
        integrate(state, token, now, limit * 4)

      :grow ->
        {:error, Relay.Error.new(:audit_batch_too_large, "one transaction exceeds the page")}

      {:ok, kept, watermark} ->
        with {:ok, integrated} <- EscapeHatch.integrated_audit_ids(Enum.map(kept, & &1.audit_id)) do
          kept
          |> Enum.reject(&MapSet.member?(integrated, &1.audit_id))
          |> append(state, Integer.to_string(watermark), token, now)
        end
    end
  end

  defp append([], state, watermark, _token, _now), do: {:ok, %{state | watermark: watermark}}

  defp append(rows, state, watermark, token, now) do
    overdue(rows, now)

    hashes =
      rows
      |> Enum.with_index(state.tree_size)
      |> Enum.map(fn {row, pos} -> Relay.Audit.leaf_hash(state.origin, pos, row) end)

    ids = Enum.map(rows, & &1.audit_id)

    case EscapeHatch.audit_leaves_append(state.origin, state.tree_size, ids, hashes, token) do
      {:ok, "appended"} -> {:ok, %{State.append(state, hashes) | watermark: watermark}}
      {:ok, "index_gap"} -> rebuild(state)
      {:ok, "not_leader"} -> :not_leader
      {:error, _} = error -> error
    end
  end

  defp overdue(rows, now) do
    oldest = rows |> Enum.map(& &1.created_at) |> Enum.min(DateTime)

    if State.overdue?(oldest, now) do
      :telemetry.execute(
        [:relay, :audit, :overdue],
        %{delay_ms: DateTime.diff(now, oldest, :millisecond)},
        %{}
      )

      Logger.error("audit record integrated after the declared checkpoint interval")
    end
  end

  @doc "Rebuilds the tree size and frontier of `state`'s origin from the stored leaves, keeping its watermark."
  @spec rebuild(State.t()) :: {:ok, State.t()} | {:error, Relay.Error.t()}
  def rebuild(%State{} = state),
    do: rebuild(State.new(state.origin, state.watermark), 0)

  defp rebuild(state, from) do
    with {:ok, leaves} <- EscapeHatch.audit_leaves(state.origin, from, @rebuild_page) do
      state = State.append(state, Enum.map(leaves, & &1.leaf_hash))

      if length(leaves) < @rebuild_page,
        do: {:ok, state},
        else: rebuild(state, from + @rebuild_page)
    end
  end

  defp sign(state, token, config) do
    now_ms = DateTime.to_unix(Relay.Clock.utc_now(), :millisecond)

    case State.decide(state, now_ms) do
      :idle -> {:ok, state}
      kind -> sign(state, kind, token, config, now_ms)
    end
  end

  defp sign(state, kind, token, config, now_ms) do
    label = Keyword.fetch!(config, :checkpoint_key)
    root = State.root(state)
    text = Relay.Audit.checkpoint_text(state.origin, state.tree_size, root)

    with {:ok, public_key} <- Relay.Keys.public_key(:ed25519, label),
         {:ok, note} <-
           Relay.Audit.sign_note(
             text,
             state.origin,
             public_key,
             &Relay.Keys.sign(:ed25519, label, &1)
           ) do
      checkpoint = %{
        id: Relay.Id.generate(),
        origin: state.origin,
        tree_size: state.tree_size,
        root_hash: root,
        signed_note: note,
        key_ref: "pkcs11:object=" <> label,
        heartbeat: kind == :heartbeat
      }

      record(state, checkpoint, token, config, now_ms)
    end
  end

  defp record(state, checkpoint, token, config, now_ms) do
    case EscapeHatch.audit_checkpoint_record(checkpoint, token) do
      {:ok, "recorded"} ->
        :telemetry.execute([:relay, :audit, :checkpoint], %{tree_size: checkpoint.tree_size}, %{
          origin: checkpoint.origin,
          heartbeat: checkpoint.heartbeat
        })

        publish(checkpoint, Keyword.get(config, :publishers, []))
        {:ok, State.signed(state, now_ms)}

      {:ok, "duplicate"} ->
        {:ok, State.signed(state, now_ms)}

      {:ok, "stale"} ->
        Logger.error("audit checkpoint older than the recorded tree", origin: checkpoint.origin)
        rebuild(state)

      {:ok, "not_leader"} ->
        :not_leader

      {:error, _} = error ->
        error
    end
  end

  @doc "Publishes a recorded checkpoint to every target and records each outcome."
  @spec publish(Publisher.checkpoint(), [{String.t(), module(), keyword()}]) :: :ok
  def publish(checkpoint, publishers) do
    published =
      Enum.count(publishers, fn {target, module, opts} ->
        {status, detail} = publish_one(checkpoint, target, module, opts)
        _ = EscapeHatch.audit_checkpoint_publication_record(checkpoint.id, target, status, detail)
        status == "published"
      end)

    if published == 0 do
      :telemetry.execute([:relay, :audit, :unpublished], %{count: 1}, %{origin: checkpoint.origin})

      Logger.error("audit checkpoint reached no publication target", origin: checkpoint.origin)
    end

    :ok
  end

  defp publish_one(checkpoint, target, module, opts) do
    with true <- Publisher.valid_target?(target) || {"failed", "invalid_target"},
         :ok <- module.publish(checkpoint, opts) do
      {"published", nil}
    else
      {:error, %Relay.Error{code: code}} -> {"failed", Atom.to_string(code)}
      {"failed", _} = failed -> failed
    end
  end

  defp config, do: Application.get_env(:relay, Relay.Audit, [])
end
