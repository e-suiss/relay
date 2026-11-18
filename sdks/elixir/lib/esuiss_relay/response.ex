defmodule EsuissRelay.Response do
  @moduledoc """
  A successful answer with its metadata, returned when a call passes `raw: true`.

  `replayed` is true when Relay answered with the stored first response of the same
  idempotency key (`Idempotency-Replayed: true`); a replay is a success.
  """

  @enforce_keys [:status, :headers, :body, :replayed, :request_id]
  defstruct [:status, :headers, :body, :replayed, :request_id]

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: term(),
          replayed: boolean(),
          request_id: String.t() | nil
        }

  # API-13
  @doc false
  @spec new(EsuissRelay.Transport.response(), term()) :: t()
  def new(response, body) do
    %__MODULE__{
      status: response.status,
      headers: response.headers,
      body: body,
      replayed: String.downcase(header(response.headers, "idempotency-replayed") || "") == "true",
      request_id: header(response.headers, "request-id")
    }
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: String.trim(value)
    end)
  end
end
