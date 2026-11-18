defmodule EsuissRelay.Transport do
  @moduledoc """
  The HTTP layer of the client. The default is `EsuissRelay.Transport.Httpc`; tests and
  applications that already run an HTTP client pass `transport: {module, state}` to
  `EsuissRelay.Client.new/1`.

  Header names in a request are lower case. The response body is the raw bytes.
  """

  @type request :: %{
          method: :get | :post | :put | :patch | :delete,
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary() | nil,
          timeout: pos_integer()
        }

  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @doc "Sends one request and returns the answer, or the reason no answer arrived."
  @callback request(state :: term(), request()) :: {:ok, response()} | {:error, term()}
end
