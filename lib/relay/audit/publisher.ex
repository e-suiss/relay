defmodule Relay.Audit.Checkpointer.Publisher do
  @moduledoc """
  Publication target of signed audit checkpoints: an object-locked store, a SIEM or a customer endpoint. At least one configured target must be independent of Relay's own operation; a checkpoint that exists only in Relay's database is no integrity claim. Targets are configured as `{target, module, options}` under `config :relay, Relay.Audit, publishers: [...]`, where `target` is `worm_store`, `siem` or `customer:<id>`.

  A target that can be read back implements `read/2`, and the read-back task compares what it returns with the recorded checkpoint; `check/1` verifies the target itself (for an object store: that object lock is on) and `probe/1`, run when a production node starts, writes to the target and reads back; a failed probe stops the node. `independent?/0` marks a target that a production node accepts as independent of Relay's own operation, and `validate/1` checks the options when the node starts (`Relay.Config`). See `Relay.Audit.Checkpointer.Publisher.S3`.
  """

  @type checkpoint :: %{
          id: Relay.Id.t(),
          origin: String.t(),
          tree_size: non_neg_integer(),
          root_hash: <<_::256>>,
          signed_note: String.t(),
          key_ref: String.t(),
          heartbeat: boolean()
        }

  @callback publish(checkpoint(), keyword()) :: :ok | {:error, Relay.Error.t()}
  @callback read(checkpoint(), keyword()) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  @callback check(keyword()) :: :ok | {:error, Relay.Error.t()}
  @callback probe(keyword()) :: :ok | {:error, Relay.Error.t()}
  @callback independent?() :: boolean()
  @callback validate(keyword()) :: :ok | {:error, String.t()}

  @optional_callbacks read: 2, check: 1, probe: 1, independent?: 0, validate: 1

  # OP-63
  # TN-46
  @doc "Returns true if `target` is a valid publication target name."
  @spec valid_target?(term()) :: boolean()
  def valid_target?("worm_store"), do: true
  def valid_target?("siem"), do: true
  def valid_target?("customer:" <> id), do: Regex.match?(~r/^[A-Za-z0-9_.-]{1,128}$/, id)
  def valid_target?(_target), do: false

  # OP-70
  @doc "Returns true if a publisher module can be read back."
  @spec readable?(module()) :: boolean()
  def readable?(module), do: exported?(module, :read, 2)

  @doc "Returns true if a publisher module checks its target."
  @spec checkable?(module()) :: boolean()
  def checkable?(module), do: exported?(module, :check, 1)

  defp exported?(module, name, arity),
    do:
      is_atom(module) and Code.ensure_loaded?(module) and function_exported?(module, name, arity)
end
