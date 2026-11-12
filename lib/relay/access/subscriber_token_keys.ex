defmodule Relay.Access.SubscriberTokenKeys do
  @moduledoc """
  The signing keys of the subscriber token (IN-51). Each key is an ES256 key pair in the key store under its label (TN-63), and the label is the token's `kid`; no JWKS is published, because only Relay verifies the token. The installation's labels live in `relay.subscriber_token_keys`: one `current` key signs, one `previous` key still verifies until `verify_until`, two token lifetimes after the rotation, and every older key is `retired`; no row is ever deleted. The installation starts with the configured label (`config :relay, Relay.Access, subscriber_token_key: label`, `subscriber-token`) as the current key, recorded when the table was created; the configured label is used only while the table is empty.

  Rotation is an operator action (`rotate/3`, through `Relay.Release.SubscriberTokenKey`): the new key pair is created in the key store first (`deploy/hsm-keys.sh`), and the rotation refuses a label the key store does not hold or one already used. The new key signs at once. On suspected compromise `retire_previous/2` retires the previous key without waiting; that change and every rotation are signalled on the system topic `topic/0`, and the realtime layer closes every open connection whose token's `kid` is no longer accepted (`accepted?/2` with `fresh: true`), as IN-33 does for a revocation. Rotation is due every 90 days (POLICY DEFAULT): the activation time of the current key is reported as the alarm metric `relay.access.subscriber_token_key.activated.timestamp_seconds`, and the alert `RelaySubscriberTokenKeyRotationDue` reminds the operator; nothing rotates automatically.

  A node reads the labels at most every five seconds (`Relay.Access.Cache`).
  """

  require Logger

  alias Relay.Access.Cache
  alias Relay.Access.SubscriberTokenKeyStore

  @cache {__MODULE__, :snapshot}
  @ttl_ms 5_000
  @rotation_days 90
  @lifetime_s Relay.Limits.fetch!(["subscriber_token_lifetime_seconds"])

  @type key :: %{label: String.t(), activated_at: DateTime.t() | nil}
  @type previous :: %{label: String.t(), verify_until: DateTime.t()}
  @type snapshot :: %{current: key(), previous: previous() | nil}

  # IN-51
  @doc "How long the previous key still verifies after a rotation: two token lifetimes."
  @spec window_s() :: pos_integer()
  def window_s, do: 2 * @lifetime_s

  # IN-51
  @doc "The rotation period after which the alarm reminds the operator (POLICY DEFAULT)."
  @spec rotation_days() :: pos_integer()
  def rotation_days, do: @rotation_days

  # IN-51
  # T-9
  @doc "The system signal topic of a key change; the realtime layer re-checks its connections' `kid` when it fires."
  @spec topic() :: String.t()
  def topic, do: Relay.Platform.system_signal_topic(["subscriber_token_keys"])

  # IN-51
  @doc "The current and previous keys, read at most every few seconds; the configured label is current before the first rotation. `fresh: true` reads the table now."
  @spec snapshot(keyword()) :: {:ok, snapshot()} | {:error, Relay.Error.t()}
  def snapshot(opts \\ []) do
    case Keyword.get(opts, :fresh, false) || Cache.fetch(@cache) do
      {:ok, snapshot} -> {:ok, snapshot}
      _stale -> load()
    end
  end

  # IN-51
  @doc "The label of the key that signs new tokens."
  @spec current_label() :: {:ok, String.t()} | {:error, Relay.Error.t()}
  def current_label do
    with {:ok, %{current: %{label: label}}} <- snapshot(), do: {:ok, label}
  end

  # IN-51
  @doc "Whether a token signed under `kid` still verifies: the current key, or the previous key before its `verify_until`. `fresh: true` reads the table now."
  @spec accepted?(String.t(), keyword()) :: {:ok, boolean()} | {:error, Relay.Error.t()}
  def accepted?(kid, opts \\ []) when is_binary(kid) do
    with {:ok, snapshot} <- snapshot(opts),
         do: {:ok, accepts?(snapshot, kid, Relay.Clock.utc_now())}
  end

  # IN-51
  @doc "Whether `snapshot` accepts `kid` at `now`: the current key always, the previous key only before its `verify_until`, a retired or unknown key never."
  @spec accepts?(snapshot(), String.t(), DateTime.t()) :: boolean()
  def accepts?(%{current: %{label: kid}}, kid, _now), do: true

  def accepts?(%{previous: %{label: kid, verify_until: %DateTime{} = until}}, kid, now),
    do: DateTime.compare(now, until) == :lt

  def accepts?(_snapshot, _kid, _now), do: false

  # IN-51
  # TN-63
  @doc "Makes `label`, a key pair already in the key store, the current key; the current key becomes the previous one and verifies for `window_s/0` more, and the key before it is retired. Returns the new and previous labels and the end of the previous key's window."
  @spec rotate(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def rotate(label, actor, reason)
      when is_binary(label) and is_binary(actor) and is_binary(reason) do
    with :ok <- in_key_store(label),
         [row] <- call("rotate", [label, default_label(), window_s(), actor, reason]) do
      rotated(row, label)
    end
  end

  defp rotated(%{"result" => "rotated"} = row, label) do
    changed()

    {:ok,
     %{
       current: label,
       previous: row["previous_label"],
       previous_verify_until: row["verify_until"]
     }}
  end

  defp rotated(%{"result" => "label_used"}, _label),
    do: {:error, Relay.Error.new(:key_exists, "the key label was already used")}

  # IN-51
  # IN-33
  @doc "Retires the previous key at once, on suspected compromise: its tokens no longer verify and the realtime layer closes their connections when the signal fires."
  @spec retire_previous(String.t(), String.t()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def retire_previous(actor, reason) when is_binary(actor) and is_binary(reason) do
    [row] = call("retire", [actor, reason])

    case row do
      %{"result" => "retired", "label" => label} ->
        changed()
        {:ok, %{retired: label}}

      %{"result" => "no_previous"} ->
        {:error, Relay.Error.new(:not_found, "there is no previous key")}
    end
  end

  # IN-51
  @doc "The current key, its activation, when its rotation is due (POLICY DEFAULT) and the previous key's window."
  @spec status() :: {:ok, map()} | {:error, Relay.Error.t()}
  def status do
    with {:ok, %{current: current, previous: previous}} <- snapshot(fresh: true) do
      at = current.activated_at
      due = at && DateTime.add(at, @rotation_days, :day)
      {:ok, %{current: current.label, activated_at: at, rotation_due_at: due, previous: previous}}
    end
  end

  defp in_key_store(label) do
    case Relay.Keys.public_key(:es256, label) do
      {:ok, <<4, _::binary-size(64)>>} ->
        :ok

      _missing ->
        {:error, Relay.Error.new(:validation_failed, "the key store holds no P-256 key pair")}
    end
  end

  defp load do
    case SubscriberTokenKeyStore.active() do
      {:ok, rows} ->
        snapshot = from_rows(rows)
        :ok = Cache.put(@cache, snapshot, @ttl_ms)
        report(snapshot)
        {:ok, snapshot}

      {:error, _error} ->
        {:error, Relay.Error.new(:service_unavailable, "the token keys are unreadable")}
    end
  end

  defp from_rows(rows) do
    current =
      Enum.find_value(rows, %{label: default_label(), activated_at: nil}, fn
        [label, "current", at, _until] -> %{label: label, activated_at: at}
        _other -> nil
      end)

    previous =
      Enum.find_value(rows, fn
        [label, "previous", _at, until] -> %{label: label, verify_until: until}
        _other -> nil
      end)

    %{current: current, previous: previous}
  end

  defp report(%{current: %{activated_at: %DateTime{} = at}}) do
    :telemetry.execute(
      [:relay, :access, :subscriber_token_key],
      %{activated_at: DateTime.to_unix(at)},
      %{}
    )
  end

  defp report(_snapshot), do: :ok

  defp changed do
    Cache.delete(@cache)
    seq = DateTime.to_unix(Relay.Clock.utc_now(), :millisecond)

    case Relay.Platform.publish_signal(topic(), seq) do
      :ok -> :ok
      {:error, error} -> Logger.warning("subscriber token key signal not sent", code: error.code)
    end
  end

  defp call(function, params), do: SubscriberTokenKeyStore.call(function, params)

  defp default_label,
    do: Keyword.get(Relay.Access.config(), :subscriber_token_key, "subscriber-token")
end
