defmodule Relay.Audit.Checkpointer.Verifier do
  @moduledoc """
  The `audit_verify` singleton task: recomputes every leaf of every yearly log from the audit records it commits to, rebuilds the roots at each recorded checkpoint's tree size, compares them with the recorded roots and verifies each signed note against the checkpoint key. It also counts audit records below the checkpoint job's watermark that never got a leaf. Any mismatch is a security event: `[:relay, :audit, :mismatch]` and an error log.
  """

  @behaviour Relay.Platform.Leadership

  require Logger

  alias Relay.Audit.Checkpointer.State
  alias Relay.Platform.Maintenance.EscapeHatch

  @every_ms 60 * 60_000
  @page 10_000

  @type finding :: %{kind: atom(), origin: String.t() | nil, detail: term()}

  # OP-63
  # OP-42
  @impl Relay.Platform.Leadership
  @doc "Verifies every log once and schedules the next run an hour later."
  @spec run(Relay.Platform.Leadership.context()) :: Relay.Platform.Leadership.step()
  def run(_context) do
    label = Keyword.fetch!(Application.get_env(:relay, Relay.Audit, []), :checkpoint_key)

    with {:ok, public_key} <- Relay.Keys.public_key(:ed25519, label),
         {:ok, findings} <- verify(public_key) do
      report(findings)

      {:ok,
       %{
         "verified_at" => DateTime.to_iso8601(Relay.Clock.utc_now()),
         "findings" => length(findings)
       }, @every_ms}
    end
  end

  @doc "Verifies every log against the checkpoint public key and returns the findings."
  @spec verify(<<_::256>>) :: {:ok, [finding()]} | {:error, Relay.Error.t()}
  def verify(public_key) do
    with {:ok, origins} <- EscapeHatch.audit_origins(),
         {:ok, findings} <- verify_origins(origins, public_key),
         {:ok, missing} <- missing() do
      {:ok, findings ++ missing}
    end
  end

  defp verify_origins(origins, public_key) do
    Enum.reduce_while(origins, {:ok, []}, fn origin, {:ok, acc} ->
      case verify_origin(origin, public_key) do
        {:ok, found} -> {:cont, {:ok, acc ++ found}}
        error -> {:halt, error}
      end
    end)
  end

  defp verify_origin(origin, public_key) do
    with {:ok, checkpoints} <- EscapeHatch.audit_checkpoints(origin) do
      verifier = Relay.Audit.verifier_key(origin, public_key)
      notes = Enum.flat_map(checkpoints, &note_findings(origin, &1, verifier))
      sizes = checkpoints |> Enum.map(& &1.tree_size) |> Enum.uniq()

      with {:ok, roots, leaf_findings} <- roots(origin, sizes),
           do: {:ok, notes ++ leaf_findings ++ root_findings(origin, checkpoints, roots)}
    end
  end

  defp root_findings(origin, checkpoints, roots) do
    for checkpoint <- checkpoints,
        not Relay.Crypto.secure_compare(
          Map.get(roots, checkpoint.tree_size, <<>>),
          checkpoint.root_hash
        ),
        do: finding(:root_mismatch, origin, checkpoint.tree_size)
  end

  defp note_findings(origin, checkpoint, verifier) do
    with {:ok, body} <- Relay.Audit.open_checkpoint(checkpoint.signed_note, [verifier]),
         true <-
           body.origin == origin and body.tree_size == checkpoint.tree_size and
             body.root_hash == checkpoint.root_hash do
      []
    else
      _ -> [finding(:note_invalid, origin, checkpoint.tree_size)]
    end
  end

  defp roots(origin, sizes) do
    wanted = MapSet.new(sizes)
    initial = if MapSet.member?(wanted, 0), do: %{0 => Relay.Audit.empty_root()}, else: %{}
    walk(origin, State.new(origin), wanted, initial, [])
  end

  defp walk(origin, state, wanted, roots, findings) do
    with {:ok, leaves} <- EscapeHatch.audit_leaves(origin, state.tree_size, @page) do
      {state, roots, findings} =
        Enum.reduce(leaves, {state, roots, findings}, &absorb(origin, wanted, &1, &2))

      if length(leaves) < @page,
        do: {:ok, roots, Enum.reverse(findings)},
        else: walk(origin, state, wanted, roots, findings)
    end
  end

  defp absorb(origin, wanted, leaf, {state, roots, findings}) do
    findings = leaf_findings(origin, state.tree_size, leaf) ++ findings
    state = State.append(state, [leaf.leaf_hash])

    roots =
      if MapSet.member?(wanted, state.tree_size),
        do: Map.put(roots, state.tree_size, State.root(state)),
        else: roots

    {state, roots, findings}
  end

  defp leaf_findings(origin, pos, leaf) do
    cond do
      leaf.leaf_index != pos ->
        [finding(:index_gap, origin, pos)]

      is_nil(leaf.record_digest) ->
        [finding(:record_missing, origin, pos)]

      not Relay.Crypto.secure_compare(Relay.Audit.leaf_hash(origin, pos, leaf), leaf.leaf_hash) ->
        [finding(:leaf_mismatch, origin, pos)]

      true ->
        []
    end
  end

  defp missing do
    with {:ok, saved} <- watermark(),
         {:ok, count} <- EscapeHatch.unintegrated_audit_records(saved) do
      if count > 0, do: {:ok, [finding(:record_unintegrated, nil, count)]}, else: {:ok, []}
    end
  end

  defp watermark do
    case Relay.Platform.Leadership.saved_state("audit_checkpoint") do
      {:ok, %{"watermark" => watermark}} when is_binary(watermark) -> {:ok, watermark}
      {:ok, _} -> {:ok, "0"}
      error -> error
    end
  end

  defp finding(kind, origin, detail), do: %{kind: kind, origin: origin, detail: detail}

  defp report(findings) do
    Enum.each(findings, fn finding ->
      :telemetry.execute([:relay, :audit, :mismatch], %{count: 1}, finding)
      Logger.error("audit verification mismatch", kind: finding.kind, origin: finding.origin)
    end)
  end
end
