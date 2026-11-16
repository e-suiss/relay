defmodule Relay.Devices do
  @moduledoc """
  Devices (C-23, API-67): the push targets of a subscriber. Other contexts use only the functions of this module.

  * A device carries its platform (`apns`, `fcm`, `hms`, `web_push`, `unified_push`), the app it belongs to, the OS notification permission, the Android channel importances, the APNs environment and when it was last registered and seen (CH-28). The token is encrypted under the subscriber's `recipient_profile` data key and found through its blind index; it is never returned, and answers and events carry only its fingerprint, a short keyed digest (API-67, CH-31).
  * A token belongs to one subscriber. Registering it again is idempotent and refreshes the device; a token another subscriber holds is moved, the old device is disabled with `reassigned` and `device.reassigned` is emitted (API-67). A subscriber keeps at most the contract's `devices.max_active_per_subscriber` active devices, which a tenant may only lower (`devices.max_active`); the registration past the limit disables the least recently seen device with `device_limit` and is never refused (CH-74).
  * Disabling is a soft delete (state, `deleted_at`, `disabled_reason`) that emits `device.unregistered`; nothing is physically deleted and preferences are never touched (C-23, CH-31, INV-14). A permanent target failure whose provider timestamp is older than the device's last registration leaves the device in place (CH-11).
  * The sweep marks devices not seen for `devices.stale_after` stale and disables devices not seen for `devices.inactive_disable_after` with `inactive`; it never runs without an upper bound (CH-31, OP-44).
  * Only devices whose permission allows the message class are targets; when a subscriber has devices but none is permitted the caller skips with `no_permission` and the route moves on (CH-28).
  * A device reports its own short-lived status signals (`Relay.Devices.Presence`, IN-47, IN-48, IN-53); they live on Valkey only, and a break transition among them releases the recipient's `next_break` deliveries (WF-56).
  * Whether a device holds an active realtime connection is asked of the realtime registry's short-lived record (`Relay.Devices.Connections`, IN-40); such a device gets no push for a notification its connection carries and no sync signal.
  * A counter change reaches the mobile devices as a sync signal (`sync/4`) and a read on one device reaches the others as a read signal (`propagate_read/5`), both sent by `Relay.Devices.SignalJob` (`Relay.Devices.Signals`, IN-35, IN-38, IN-52). The badge number of a push is the count the counter write returned, in its platform form (`badge/3`, IN-20).

  Functions documented to run inside the caller's scoped transaction say so; the others open their own and must not be called inside one.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Platform, Relay.Tenancy], exports: []

  alias Relay.Devices.Badge
  alias Relay.Devices.Connections
  alias Relay.Devices.Presence
  alias Relay.Devices.Signals
  alias Relay.Devices.Store
  alias Relay.Devices.Token
  alias Relay.Scope

  @max_active Relay.Limits.fetch!(["devices", "max_active_per_subscriber"])
  @stale_after_s Relay.Limits.seconds!(["devices", "stale_after"])
  @inactive_after_s Relay.Limits.seconds!(["devices", "inactive_disable_after"])
  @sweep_batch Relay.Limits.fetch!(["devices", "sweep_batch_max"])
  @purpose "device_token"
  @reasons %{unregistered: "unregistered", logout: "logout", removed: "removed"}

  @type plan :: map()
  @type target :: %{
          id: Relay.Id.t(),
          platform: String.t(),
          app: String.t(),
          token: Relay.Redacted.t(),
          keys: Relay.Redacted.t() | nil,
          apns_environment: String.t() | nil,
          android_channels: [map()],
          locale: String.t() | nil,
          permission: String.t(),
          fingerprint: String.t()
        }
  @type reason :: :unregistered | :logout | :removed
  @type sweep_result :: %{
          staled: non_neg_integer(),
          disabled: non_neg_integer(),
          has_more: boolean()
        }
  @type ref :: {:device, Relay.Id.t()} | {:token, String.t()}
  @type counters :: %{
          optional(:version) => non_neg_integer(),
          optional(:unseen) => non_neg_integer(),
          optional(:unread) => non_neg_integer(),
          optional(:uncertain) => boolean()
        }

  @doc "Sends one sync signal to a device; the channel step implements it (`Relay.Channels.Live`). `target` is a push target, `signal` a `t:Relay.Devices.Signals.signal/0`."
  @callback send_signal(Scope.t(), target(), Signals.signal()) :: :ok | {:error, term()}

  # CH-74
  @doc "The contract's active device limit per subscriber."
  @spec max_active() :: pos_integer()
  def max_active, do: @max_active

  # API-67
  # CH-28
  # TN-33
  @doc "Prepares a registration outside any transaction: the body is checked and normalised, the token and any previous token are digested under every readable blind index key, and the stored token is encrypted under the recipient's `recipient_profile` data key."
  @spec prepare(Scope.t(), Relay.Id.t(), map()) :: {:ok, plan()} | {:error, Relay.Error.t()}
  def prepare(%Scope{} = scope, recipient_id, body) do
    with {:ok, registration} <- Token.registration(body),
         {:ok, [{key_id, _mac} | _] = entries} <- index(scope, registration.token),
         {:ok, previous} <- previous_digests(scope, registration.previous_token),
         {:ok, token_ct} <- seal(scope, recipient_id, Token.stored(registration)) do
      {:ok,
       %{
         recipient_id: recipient_id,
         platform: registration.platform,
         app: registration.app,
         digests: Enum.map(entries, &elem(&1, 1)),
         bidx_key_id: key_id,
         token_ct: token_ct,
         apns_environment: registration.apns_environment,
         permission: registration.permission,
         android_channels: registration.android_channels,
         locale: registration.locale,
         previous_digests: previous
       }}
    end
  end

  defp previous_digests(_scope, nil), do: {:ok, nil}

  defp previous_digests(scope, token) do
    with {:ok, entries} <- index(scope, token), do: {:ok, Enum.map(entries, &elem(&1, 1))}
  end

  # API-67
  @doc "The blind indexes of a token the caller names, under every readable key, computed outside any transaction."
  @spec token_digests(Scope.t(), String.t()) :: {:ok, [binary()]} | {:error, Relay.Error.t()}
  def token_digests(%Scope{} = scope, token) when is_binary(token) do
    with {:ok, entries} <- index(scope, Token.lookup(token)),
         do: {:ok, Enum.map(entries, &elem(&1, 1))}
  end

  defp index(scope, token) do
    index_scope = %{tenant_id: scope.tenant_id, environment: scope.environment, purpose: @purpose}

    case Relay.Tenancy.blind_index_digests(index_scope, token) do
      {:ok, entries} -> {:ok, entries}
      {:error, %Relay.Error{} = error} -> {:error, error}
    end
  end

  defp seal(scope, recipient_id, value) do
    case Relay.Tenancy.encrypt_field(field(scope, recipient_id), value) do
      {:ok, ciphertext} -> {:ok, ciphertext}
      {:error, %Relay.Error{} = error} -> {:error, error}
    end
  end

  defp field(scope, recipient_id) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: recipient_id,
      retention_class: :recipient_profile,
      table: "devices",
      column: "token_ct"
    }
  end

  # API-67
  # CH-74
  @doc "Registers a prepared device inside the caller's scoped transaction under the subscriber's active device limit; returns the result (`:created`, `:updated`, `:reassigned`, `:recipient_not_found` or `:key_not_found`) and the device's identifier."
  @spec register(plan()) :: {atom(), Relay.Id.t() | nil}
  def register(plan), do: Store.register(plan, limit())

  defp limit do
    case Store.limit_setting() do
      setting when is_integer(setting) and setting >= 1 -> min(setting, @max_active)
      _unset -> @max_active
    end
  end

  # API-67
  @doc "Reads a device inside the caller's scoped transaction, or `nil`."
  @spec get(Relay.Id.t()) :: map() | nil
  defdelegate get(device_id), to: Store

  # API-67
  @doc "The devices of a recipient that are not disabled, most recently seen first, inside the caller's scoped transaction."
  @spec current(Relay.Id.t()) :: [map()]
  def current(recipient_id), do: Store.current(recipient_id, Token.platforms())

  # API-67
  @doc "The devices of a recipient that are not disabled, most recently seen first, in their own transaction."
  @spec list(Scope.t(), Relay.Id.t()) :: {:ok, [map()]} | {:error, term()}
  def list(%Scope{} = scope, recipient_id),
    do: Store.in_scope(scope, fn _status -> current(recipient_id) end)

  # CH-11
  # CH-31
  @doc "Disables a device inside the caller's scoped transaction, found by identifier or by token digests and, with `recipient_id`, only among that recipient's devices. `failed_at` is the provider's time of a permanent failure; a device registered after it is left in place. The result is `:disabled`, `:already_disabled`, `:reregistered` or `:not_found`."
  @spec remove(
          {:device, Relay.Id.t()} | {:digests, [binary()]},
          Relay.Id.t() | nil,
          reason(),
          DateTime.t() | nil
        ) :: {atom(), Relay.Id.t() | nil}
  def remove(ref, recipient_id, reason, failed_at \\ nil) do
    {device_id, digests} =
      case ref do
        {:device, id} -> {id, nil}
        {:digests, digests} -> {nil, digests}
      end

    Store.disable(device_id, digests, recipient_id, Map.fetch!(@reasons, reason), failed_at)
  end

  # INV-14
  # CH-11
  # OP-44
  @doc """
  Disables a device after a permanent target failure, or a logout, in its own transaction: the channel adapters call it when the provider reports the token invalid (APNs 410, FCM `UNREGISTERED`, Web Push 404 or 410). `ref` names the device by identifier or by its token. With `failed_at` (the APNs 410 `timestamp`), a device registered again after that time is left in place and the answer is `:reregistered`. A disabled device answers `:already_disabled`; the change emits `device.unregistered`.
  """
  @spec disable(Scope.t(), ref(), reason(), keyword()) :: {:ok, atom()} | {:error, term()}
  def disable(%Scope{} = scope, ref, reason \\ :unregistered, opts \\ [])
      when is_map_key(@reasons, reason) do
    failed_at = Keyword.get(opts, :failed_at)

    with {:ok, resolved} <- resolve(scope, ref),
         {:ok, {result, _id}} <- removed(scope, resolved, reason, failed_at),
         do: {:ok, result}
  end

  defp removed(scope, ref, reason, failed_at),
    do: Store.in_scope(scope, fn _status -> remove(ref, nil, reason, failed_at) end)

  defp resolve(_scope, {:device, id}) when is_binary(id), do: {:ok, {:device, id}}

  defp resolve(scope, {:token, token}) when is_binary(token) do
    with {:ok, digests} <- token_digests(scope, token), do: {:ok, {:digests, digests}}
  end

  # CH-28
  # CH-29
  # CH-31
  @doc """
  The push targets of a recipient on a channel (`:push` or `:web_push`) for a message class, in their own transaction and decrypted outside it: devices that are not disabled and whose permission allows the class, most recently seen first. `{:skip, :no_device}` when the recipient has no such device on the channel and `{:skip, :no_permission}` when it has some but none is permitted; the caller records the skip and the route moves on. Tokens and Web Push keys come back redacted.
  """
  @spec targets(Scope.t(), Relay.Id.t(), :push | :web_push, atom() | String.t() | nil) ::
          {:ok, [target()]} | {:skip, :no_device | :no_permission} | {:error, term()}
  def targets(%Scope{} = scope, recipient_id, channel, message_class) do
    with {:ok, rows} <- read(scope, recipient_id, Token.platforms(channel)) do
      permitted = Enum.filter(rows, &Token.permitted?(&1["permission"], message_class))

      cond do
        rows == [] -> {:skip, :no_device}
        permitted == [] -> {:skip, :no_permission}
        true -> open(scope, permitted)
      end
    end
  end

  defp read(scope, recipient_id, platforms),
    do: Store.in_scope(scope, fn _status -> Store.current(recipient_id, platforms) end)

  defp open(scope, rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case Relay.Tenancy.decrypt_field(field(scope, row["recipient_id"]), row["token_ct"]) do
        {:ok, value} -> {:cont, {:ok, [target(row, value) | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, targets} -> {:ok, Enum.reverse(targets)}
      error -> error
    end
  end

  defp target(row, value) do
    {token, keys} = Token.unstored(row["platform"], Relay.Redacted.expose(value))

    %{
      id: row["id"],
      platform: row["platform"],
      app: row["app"],
      token: Relay.Redacted.wrap(token),
      keys: keys && Relay.Redacted.wrap(keys),
      apns_environment: row["apns_environment"],
      android_channels: row["android_channels"],
      locale: row["locale"],
      permission: row["permission"],
      fingerprint: row["fingerprint"]
    }
  end

  # CH-28
  @doc "Whether a device permission allows a message class; see `Relay.Devices.Token.permitted?/2`."
  @spec permitted?(String.t(), atom() | String.t() | nil) :: boolean()
  defdelegate permitted?(permission, message_class), to: Token

  # C-23
  @doc "The channel a device platform serves: `:web_push` for `web_push`, `:push` for the others."
  @spec channel(String.t()) :: :push | :web_push
  defdelegate channel(platform), to: Token

  # CH-31
  # OP-44
  @doc "Marks stale and disables inactive devices of a scope in its own transaction, at most `:limit` of them (the contract's `devices.sweep_batch_max` by default); `has_more` says another run has work."
  @spec sweep(Scope.t(), keyword()) :: {:ok, sweep_result()} | {:error, term()}
  def sweep(%Scope{} = scope, opts \\ []) do
    limit = Keyword.get(opts, :limit, @sweep_batch)

    if is_integer(limit) and limit >= 1 and limit <= @sweep_batch do
      swept(scope, limit)
    else
      {:error, Relay.Error.new(:invalid_limit, "the sweep needs a bound within the contract")}
    end
  end

  defp swept(scope, limit) do
    work = fn _status -> Store.sweep(@stale_after_s, @inactive_after_s, limit) end

    case Store.in_scope(scope, work) do
      {:ok, %{"staled" => staled, "disabled" => disabled, "has_more" => more}} ->
        {:ok, %{staled: staled, disabled: disabled, has_more: more}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # CH-31
  # OP-44
  @doc "Sweeps every scope that has a device to mark stale or disable, at most `limit` scopes; returns the number of scopes swept."
  @spec sweep_due(pos_integer()) :: non_neg_integer()
  def sweep_due(limit \\ 100) when is_integer(limit) and limit > 0 do
    @stale_after_s
    |> Store.sweep_scopes(@inactive_after_s, limit)
    |> Enum.count(fn {tenant_id, environment} ->
      with {:ok, scope} <- Scope.new(tenant_id, environment), {:ok, _swept} <- sweep(scope) do
        true
      else
        _other -> false
      end
    end)
  end

  # IN-47
  # IN-53
  @doc "The signal names of a device status dictionary version, or `nil` for a version that does not exist."
  @spec status_signals(String.t()) :: [String.t()] | nil
  defdelegate status_signals(version), to: Presence, as: :signals

  # IN-53
  @doc "The default and the longest time to live of a device status signal, in milliseconds."
  @spec status_ttl_ms() :: %{default: pos_integer(), max: pos_integer()}
  def status_ttl_ms, do: %{default: Presence.default_ttl_ms(), max: Presence.max_ttl_ms()}

  # IN-47
  # IN-53
  # WF-56
  @doc """
  Writes the changed status signals of one of the subscriber's own devices with their time to live in milliseconds, cut at the ceiling. The device is read in its own transaction: a device of another subscriber, a disabled or an unknown one is `{:error, :device_not_found}`. The status itself goes to Valkey only. Answers the device's signals after the write and whether the write was a break transition; `{:error, :rate_limited}` for a second write within the device's interval and `{:error, :unavailable}` when Valkey or the database cannot be reached.
  """
  @spec status_write(Scope.t(), Relay.Id.t(), Relay.Id.t(), map(), pos_integer()) ::
          {:ok, Presence.written()}
          | {:error, :device_not_found | :rate_limited | :unavailable}
  def status_write(%Scope{} = scope, subscriber_id, device_id, changes, ttl_ms) do
    case Store.in_scope(scope, fn _status -> Store.get(device_id) end) do
      {:ok, %{"recipient_id" => ^subscriber_id, "state" => state}} when state != "disabled" ->
        Presence.write(scope, device_id, changes, ttl_ms)

      {:ok, _other} ->
        {:error, :device_not_found}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  # IN-47
  @doc "The status signals of the subscriber's devices that are not disabled, most recently seen first: each device's identifier, platform and signals; a signal is `:unknown` when it expired, was never written or Valkey cannot be read."
  @spec status(Scope.t(), Relay.Id.t()) :: {:ok, [map()]} | {:error, term()}
  def status(%Scope{} = scope, subscriber_id) do
    with {:ok, rows} <- list(scope, subscriber_id) do
      {:ok, Enum.map(rows, &device_status(scope, &1))}
    end
  end

  defp device_status(scope, row) do
    %{device_id: row["id"], platform: row["platform"], signals: Presence.read(scope, row["id"])}
  end

  # IN-40
  @doc "Whether a device of a subscriber holds an active realtime connection; see `Relay.Devices.Connections.connected?/3`."
  @spec connected?(Scope.t(), Relay.Id.t(), Relay.Id.t()) :: boolean()
  defdelegate connected?(scope, subscriber_id, device_id), to: Connections

  # IN-20
  @doc "The badge members of a push to a device of `platform` for the counters a counter write returned, counting `unseen` or `unread`; see `Relay.Devices.Badge`."
  @spec badge(String.t(), counters() | nil, :unseen | :unread) :: map()
  def badge(platform, counters, source \\ :unseen),
    do: Badge.members(platform, Badge.count(counters, source))

  # IN-35
  # IN-52
  # T-15
  @doc """
  Queues a sync signal to the mobile devices of a subscriber after its counters changed (IN-35). `counters` is the result of the counter write itself; only its `version` travels. Call it inside the transaction that wrote the counters, so the job commits with them; `except_device_id:` leaves out the device the change came from.
  """
  @spec sync(Scope.t(), Relay.Id.t(), counters(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def sync(%Scope{} = scope, subscriber_id, counters, opts \\ []) do
    attrs = %{
      counter_version: version(counters),
      except_device_id: Keyword.get(opts, :except_device_id)
    }

    queue_signal(scope, subscriber_id, :sync, attrs)
  end

  # IN-38
  # IN-35
  # T-15
  @doc """
  Propagates a read to the subscriber's other devices (IN-38). The inbox calls it when an item's read state changes on one device, inside the transaction that wrote the state and the counters, with the counters that write returned; only their `version` travels. It queues one `Relay.Devices.SignalJob`: an Android device gets a read signal naming the notification, so the SDK cancels the shown notification at once; an iOS device gets a throttled sync signal, after which the SDK removes it; a device with an active realtime connection gets the change on its connection instead. `except_device_id:` leaves out the device the read came from.
  """
  @spec propagate_read(Scope.t(), Relay.Id.t(), Relay.Id.t(), counters(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def propagate_read(%Scope{} = scope, subscriber_id, notification_id, counters, opts \\ []) do
    attrs = %{
      counter_version: version(counters),
      notification_id: notification_id,
      except_device_id: Keyword.get(opts, :except_device_id)
    }

    queue_signal(scope, subscriber_id, :read, attrs)
  end

  defp queue_signal(scope, subscriber_id, kind, attrs) do
    scope
    |> Signals.job_args(subscriber_id, kind, attrs)
    |> Relay.Devices.SignalJob.new()
    |> Oban.insert()
  end

  defp version(%{version: n}) when is_integer(n) and n >= 0, do: n
  defp version(%{"version" => n}) when is_integer(n) and n >= 0, do: n
  defp version(_counters), do: nil

  # IN-35
  # IN-38
  # IN-52
  @doc "Runs a queued signal with its job arguments: reads the subscriber's mobile devices and sends each its signal; see `Relay.Devices.Signals.run/4`."
  @spec run_signal(Scope.t(), Relay.Id.t(), map()) ::
          {:ok, %{Relay.Id.t() => Signals.outcome()}} | {:error, term()}
  def run_signal(%Scope{} = scope, subscriber_id, args) do
    with {:ok, rows} <- read(scope, subscriber_id, Signals.platforms()),
         {:ok, targets} <- open(scope, rows) do
      {:ok, Signals.run(scope, subscriber_id, targets, args)}
    end
  end
end
