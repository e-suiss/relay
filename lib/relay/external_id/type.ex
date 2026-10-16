defmodule Relay.ExternalId.Type do
  @moduledoc """
  Ecto type for identifiers that cross the API as external identifiers (`Relay.ExternalId`). The field holds the 16-byte UUIDv7 and is stored as `uuid`; casting accepts only an external identifier whose prefix is one of the field's prefixes.

      field :recipient_id, Relay.ExternalId.Type, prefixes: ["rcp", "sub", "agt"]
  """

  use Ecto.ParameterizedType

  # API-9
  # T-58 (6)
  @impl true
  def init(opts) do
    prefixes = Keyword.get_lazy(opts, :prefixes, fn -> [Keyword.fetch!(opts, :prefix)] end)

    unless prefixes != [] and Enum.all?(prefixes, &(&1 in Relay.ExternalId.prefixes())),
      do: raise(ArgumentError, "unknown external identifier prefixes: #{inspect(prefixes)}")

    %{prefixes: prefixes}
  end

  @impl true
  def type(_params), do: :binary

  @impl true
  def cast(nil, _params), do: {:ok, nil}

  def cast(text, %{prefixes: prefixes}) when is_binary(text) do
    case Relay.ExternalId.decode(text, prefixes) do
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
end
