defmodule Relay.Audit.Checkpointer.State do
  @moduledoc """
  Pure state of the audit checkpoint job: the log origin of the current yearly shard, the xid8 watermark below which every audit row is integrated, the tree size and frontier, and when the last checkpoint was signed. The job integrates new rows within the declared interval and signs a heartbeat when nothing changed for a minute.
  """

  @interval_ms 1_000
  @heartbeat_ms 60_000

  @enforce_keys [:origin, :watermark, :tree_size, :frontier]
  defstruct [:origin, :watermark, :tree_size, :frontier, last_signed_ms: nil, signed_size: nil]

  @type t :: %__MODULE__{
          origin: String.t(),
          watermark: String.t(),
          tree_size: non_neg_integer(),
          frontier: [Relay.Audit.hash()],
          last_signed_ms: integer() | nil,
          signed_size: non_neg_integer() | nil
        }

  @type pending :: %{
          required(:txid) => non_neg_integer(),
          required(:created_at) => DateTime.t(),
          required(:audit_id) => Relay.Id.t(),
          optional(atom()) => term()
        }

  # OP-63
  @doc "Declared checkpoint interval when new records exist, in milliseconds."
  @spec interval_ms() :: pos_integer()
  def interval_ms, do: @interval_ms

  @doc "Heartbeat interval when no record arrived, in milliseconds."
  @spec heartbeat_ms() :: pos_integer()
  def heartbeat_ms, do: @heartbeat_ms

  @doc "Returns the log origin of an installation host for a UTC year: `<host>/relay/audit/<year>`."
  @spec origin(String.t(), pos_integer()) :: String.t()
  def origin(host, year) when is_binary(host) and host != "" and is_integer(year) and year > 0 do
    true = Regex.match?(~r/^[A-Za-z0-9.-]+(:[0-9]+)?$/, host)
    "#{host}/relay/audit/#{year}"
  end

  @doc "Returns a fresh state for `origin`."
  @spec new(String.t(), String.t()) :: t()
  def new(origin, watermark \\ "0"),
    do: %__MODULE__{origin: origin, watermark: watermark, tree_size: 0, frontier: []}

  @doc "Moves to a new yearly shard if `origin` differs; the watermark carries over."
  @spec rotate(t(), String.t()) :: t()
  def rotate(%__MODULE__{origin: origin} = state, origin), do: state
  def rotate(%__MODULE__{} = state, origin), do: new(origin, state.watermark)

  @doc "Returns the current root hash."
  @spec root(t()) :: Relay.Audit.hash()
  def root(%__MODULE__{frontier: frontier}), do: Relay.Audit.frontier_root(frontier)

  @doc "Appends leaf hashes in order."
  @spec append(t(), [Relay.Audit.hash()]) :: t()
  def append(%__MODULE__{} = state, leaves) do
    Enum.reduce(leaves, state, fn leaf, acc ->
      %{
        acc
        | frontier: Relay.Audit.frontier_append(acc.frontier, acc.tree_size, leaf),
          tree_size: acc.tree_size + 1
      }
    end)
  end

  @doc """
  Splits a page of pending rows into the rows to integrate now and the next watermark. A short page is integrated entirely and the watermark moves to `upper`. A full page is cut before its largest transaction id, which becomes the watermark, so that no transaction is split; a full page of one transaction is `:grow`, asking for a larger page.
  """
  @spec select([pending()], pos_integer(), non_neg_integer()) ::
          {:ok, [pending()], non_neg_integer()} | :grow
  def select(rows, limit, upper) when is_list(rows) and is_integer(limit) and limit > 0 do
    sorted =
      Enum.sort_by(rows, &{&1.txid, DateTime.to_unix(&1.created_at, :microsecond), &1.audit_id})

    if length(rows) < limit do
      {:ok, sorted, upper}
    else
      max = sorted |> List.last() |> Map.fetch!(:txid)

      case Enum.reject(sorted, &(&1.txid == max)) do
        [] -> :grow
        kept -> {:ok, kept, max}
      end
    end
  end

  @doc "Decides whether to sign now: `:checkpoint` for a grown tree, `:heartbeat` after a quiet minute, otherwise `:idle`."
  @spec decide(t(), integer()) :: :checkpoint | :heartbeat | :idle
  def decide(%__MODULE__{signed_size: nil}, _now_ms), do: :checkpoint

  def decide(%__MODULE__{tree_size: size, signed_size: signed}, _now_ms) when size != signed,
    do: :checkpoint

  def decide(%__MODULE__{last_signed_ms: nil}, _now_ms), do: :heartbeat

  def decide(%__MODULE__{last_signed_ms: last}, now_ms) when now_ms - last >= @heartbeat_ms,
    do: :heartbeat

  def decide(%__MODULE__{}, _now_ms), do: :idle

  @doc "Records that the current tree was signed at `now_ms`, Unix milliseconds by the wall clock."
  @spec signed(t(), integer()) :: t()
  def signed(%__MODULE__{} = state, now_ms),
    do: %{state | last_signed_ms: now_ms, signed_size: state.tree_size}

  @doc "Returns true if integrating a row created at `created_at` at `now` exceeded the declared interval."
  @spec overdue?(DateTime.t(), DateTime.t()) :: boolean()
  def overdue?(%DateTime{} = created_at, %DateTime{} = now),
    do: DateTime.diff(now, created_at, :millisecond) > @interval_ms

  @doc "Serializes the state for `singleton_tasks.state`."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = state) do
    %{
      "origin" => state.origin,
      "watermark" => state.watermark,
      "tree_size" => state.tree_size,
      "frontier" => Enum.map(state.frontier, &Base.encode64/1),
      "signed_size" => state.signed_size,
      "signed_at_ms" => state.last_signed_ms
    }
  end

  @doc "Restores a state saved by `to_json/1`; anything else is `:error`."
  @spec from_json(term()) :: {:ok, t()} | :error
  def from_json(
        %{
          "origin" => origin,
          "watermark" => watermark,
          "tree_size" => size,
          "frontier" => encoded
        } = json
      )
      when is_binary(origin) and is_binary(watermark) and is_integer(size) and size >= 0 and
             is_list(encoded) do
    with {:ok, frontier} <- decode_all(encoded),
         true <- Relay.Audit.frontier_valid?(frontier, size),
         true <- Regex.match?(~r/^[0-9]+$/, watermark) do
      signed = Map.get(json, "signed_size")
      signed_at = Map.get(json, "signed_at_ms")

      {:ok,
       %__MODULE__{
         origin: origin,
         watermark: watermark,
         tree_size: size,
         frontier: frontier,
         signed_size: if(is_integer(signed), do: signed),
         last_signed_ms: if(is_integer(signed_at), do: signed_at)
       }}
    else
      _ -> :error
    end
  end

  def from_json(_json), do: :error

  defp decode_all(encoded) do
    Enum.reduce_while(encoded, {:ok, []}, fn item, {:ok, acc} ->
      case is_binary(item) && Base.decode64(item) do
        {:ok, <<_::256>> = hash} -> {:cont, {:ok, [hash | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      :error -> :error
    end
  end
end
