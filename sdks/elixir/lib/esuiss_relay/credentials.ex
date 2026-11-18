defprotocol EsuissRelay.Credentials do
  @moduledoc """
  Where the client gets its DPoP-bound Access access token and the key it is bound to.

  `EsuissRelay.Credentials.Static` holds a token obtained elsewhere;
  `EsuissRelay.Credentials.AccessClient` obtains and caches one with the OAuth 2.0 client
  credentials grant of an Access API client.
  """

  @doc "The current access token and its DPoP key."
  @spec token(t(), EsuissRelay.Client.t()) ::
          {:ok, String.t(), EsuissRelay.DpopKey.t()} | {:error, EsuissRelay.Error.t()}
  def token(credentials, client)
end

defmodule EsuissRelay.Credentials.Static do
  @moduledoc "A DPoP-bound access token obtained outside the SDK, with the key it is bound to."

  @enforce_keys [:token, :key]
  defstruct [:token, :key]

  @type t :: %__MODULE__{token: String.t(), key: EsuissRelay.DpopKey.t()}

  @doc "Credentials of a token and its DPoP key."
  @spec new(String.t(), EsuissRelay.DpopKey.t()) :: t()
  def new(token, %EsuissRelay.DpopKey{} = key) when is_binary(token),
    do: %__MODULE__{token: token, key: key}

  defimpl EsuissRelay.Credentials do
    def token(%{token: token, key: key}, _client), do: {:ok, token, key}
  end

  defimpl Inspect do
    def inspect(_credentials, _opts), do: "#EsuissRelay.Credentials.Static<redacted>"
  end
end
