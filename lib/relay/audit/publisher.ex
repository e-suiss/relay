defmodule Relay.Audit.Checkpointer.Publisher do
  @moduledoc """
  Publication target of signed audit checkpoints: an object-locked store, a SIEM or a customer endpoint. At least one configured target must be independent of Relay's own operation; a checkpoint that exists only in Relay's database is no integrity claim. Targets are configured as `{target, module, options}` under `config :relay, Relay.Audit, publishers: [...]`, where `target` is `worm_store`, `siem` or `customer:<id>`.
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

  # OP-63
  # TN-46
  @doc "Returns true if `target` is a valid publication target name."
  @spec valid_target?(term()) :: boolean()
  def valid_target?("worm_store"), do: true
  def valid_target?("siem"), do: true
  def valid_target?("customer:" <> id), do: Regex.match?(~r/^[A-Za-z0-9_.-]{1,128}$/, id)
  def valid_target?(_target), do: false
end
