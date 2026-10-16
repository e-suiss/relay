defmodule Relay.Platform.Valkey.Key do
  @moduledoc """
  Valkey key and channel names. A tenant key always carries the tenant and environment prefix and a time to live; names are built from validated binary segments and never become atoms. System channels live in a separate namespace that no tenant name can reach.
  """

  @enforce_keys [:name, :ttl_ms]
  defstruct [:name, :ttl_ms]

  @type t :: %__MODULE__{name: String.t(), ttl_ms: pos_integer()}
  @type segment :: String.t()

  @root "relay"
  @tenant_scope "t"
  @system_scope "s"
  @segment ~r/\A[0-9A-Za-z_.\-]{1,128}\z/

  # TN-17
  # T-9 (7)
  @doc "Builds a tenant key with its time to live in milliseconds."
  @spec new(segment(), segment(), [segment(), ...], pos_integer()) ::
          {:ok, t()} | {:error, Relay.Error.t()}
  def new(tenant_id, environment, segments, ttl_ms)
      when is_integer(ttl_ms) and ttl_ms > 0 do
    with {:ok, name} <- tenant_name(tenant_id, environment, segments) do
      {:ok, %__MODULE__{name: name, ttl_ms: ttl_ms}}
    end
  end

  def new(_tenant_id, _environment, _segments, ttl_ms),
    do:
      {:error, Relay.Error.new(:invalid_key, "a Valkey key needs a positive TTL", %{ttl: ttl_ms})}

  # TN-17
  @doc "Builds a tenant pub/sub channel name."
  @spec channel(segment(), segment(), [segment(), ...]) ::
          {:ok, String.t()} | {:error, Relay.Error.t()}
  def channel(tenant_id, environment, segments),
    do: tenant_name(tenant_id, environment, segments)

  @doc "Builds a system channel name from fixed segments; raises on an invalid segment."
  @spec system_channel([segment(), ...]) :: String.t()
  def system_channel([_ | _] = segments) do
    if Enum.all?(segments, &segment?/1),
      do: join([@root, @system_scope | segments]),
      else: raise(ArgumentError, "invalid system channel segments: #{inspect(segments)}")
  end

  @doc "Returns true if the value is a valid name segment."
  @spec segment?(term()) :: boolean()
  def segment?(value), do: is_binary(value) and Regex.match?(@segment, value)

  defp tenant_name(tenant_id, environment, [_ | _] = segments) do
    parts = [tenant_id, environment | segments]

    if Enum.all?(parts, &segment?/1),
      do: {:ok, join([@root, @tenant_scope | parts])},
      else: invalid(parts)
  end

  defp tenant_name(tenant_id, environment, segments),
    do: invalid([tenant_id, environment, segments])

  defp invalid(parts),
    do:
      {:error,
       Relay.Error.new(:invalid_key, "invalid Valkey name segments", %{segments: length(parts)})}

  defp join(parts), do: Enum.join(parts, ":")
end
