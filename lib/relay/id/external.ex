defmodule Relay.Id.External do
  @moduledoc """
  Ecto type for identifiers that cross the API as external identifiers. The field holds the 16-byte UUIDv7 and is stored as `uuid`; casting accepts only an external identifier whose prefix is one of the field's kinds.

      field :recipient_id, Relay.Id.External, kinds: [:recipient, :subscriber, :agent]
  """

  use Ecto.ParameterizedType

  # API-9
  # API-72
  @impl true
  def init(opts) do
    kinds = opts |> Keyword.get_lazy(:kinds, fn -> [Keyword.fetch!(opts, :kind)] end)
    known = Keyword.keys(Relay.Id.prefixes())

    unless kinds != [] and Enum.all?(kinds, &(&1 in known)),
      do: raise(ArgumentError, "unknown external identifier kinds: #{inspect(kinds)}")

    %{kinds: kinds}
  end

  @impl true
  def type(_params), do: :binary

  @impl true
  def cast(nil, _params), do: {:ok, nil}

  def cast(text, %{kinds: kinds}) when is_binary(text) do
    case Relay.Id.decode(text, kinds) do
      {:ok, id} -> {:ok, id}
      {:error, _} -> {:error, message: "is not a valid identifier"}
    end
  end

  def cast(_value, _params), do: :error

  @impl true
  def load(nil, _loader, _params), do: {:ok, nil}
  def load(<<_::128>> = id, _loader, _params), do: {:ok, id}
  def load(_value, _loader, _params), do: :error

  @impl true
  def dump(nil, _dumper, _params), do: {:ok, nil}

  def dump(<<_::128>> = id, _dumper, _params) do
    if Relay.Id.valid?(id), do: {:ok, id}, else: :error
  end

  def dump(_value, _dumper, _params), do: :error

  @doc "Encodes a field value as an external identifier of `kind`."
  @spec to_external(Relay.Id.t(), Relay.Id.kind()) :: String.t()
  def to_external(id, kind), do: Relay.Id.encode(kind, id)
end
