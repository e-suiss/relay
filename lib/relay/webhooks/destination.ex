defmodule Relay.Webhooks.Destination do
  @moduledoc """
  The port every destination kind sits behind (WH-17): HTTPS endpoints, brokers, cloud queues and object stores. An implementation makes one delivery attempt and reports what happened; it never retries, and it decides nothing. `Relay.Webhooks.Outcome` turns the report into a decision.

  The caller prepares the message once per attempt: the structured body, the profile headers already signed over that body, and, for the queue and stream bindings, the context attributes of binary mode with the bare `data` body. The ordering key of the event travels with it, so that a partitioned destination can map it to its partition key (WH-20 (3)).

  A receipt and a failure carry what the attempt log needs (WH-10): the duration, the address the destination was reached at and, for HTTP, the status, the response headers and at most the first bytes of the response body the caller allowed. They never carry a credential (WH-19).
  """

  alias Relay.Webhooks.Envelope

  @type prepared :: %{
          id: String.t(),
          type: String.t(),
          attempt: pos_integer(),
          headers: [{String.t(), String.t()}],
          body: binary(),
          content_type: String.t(),
          attributes: [{String.t(), String.t()}],
          data: binary(),
          partition_key: String.t() | nil
        }
  @type receipt :: %{
          required(:kind) => :http | :write,
          required(:duration_ms) => non_neg_integer(),
          required(:address) => String.t() | nil,
          optional(:status) => non_neg_integer(),
          optional(:headers) => [{String.t(), String.t()}],
          optional(:body) => binary(),
          optional(:truncated) => boolean()
        }
  @type failure_class ::
          :invalid
          | :blocked
          | :dns
          | :connect
          | :timeout
          | :tls
          | :protocol
          | :credentials
          | :rejected
          | :unavailable
  @type failure :: %{
          class: failure_class(),
          reason: String.t(),
          duration_ms: non_neg_integer(),
          address: String.t() | nil
        }

  # WH-17
  # WH-18
  @doc """
  Makes one delivery attempt to the destination described by `config`.

  `{:ok, receipt}` means the destination answered: an HTTP response of any status (`kind: :http`), or the acknowledgement of a durable write by a broker, queue or object store (`kind: :write`). `{:error, failure}` means it did not: the class says whether the destination could not be reached, refused the message for good (`:rejected`), is not available now (`:unavailable`) or was never tried because its configuration is invalid or its address is blocked.
  """
  @callback deliver(config :: map(), prepared(), opts :: keyword()) ::
              {:ok, receipt()} | {:error, failure()}

  # WH-8 (3)
  # WH-20 (3)
  @doc "Prepares one attempt of an envelope: `headers` are the profile headers the caller signed over `body`, the structured body of the envelope."
  @spec prepare(Envelope.t(), binary(), [{String.t(), String.t()}], pos_integer()) :: prepared()
  def prepare(%Envelope{} = envelope, body, headers, attempt)
      when is_binary(body) and is_list(headers) and is_integer(attempt) and attempt >= 1 do
    %{
      id: envelope.id,
      type: envelope.type,
      attempt: attempt,
      headers: headers,
      body: body,
      content_type: Envelope.content_type(),
      attributes: Envelope.attributes(envelope),
      data: Envelope.data_body(envelope),
      partition_key: Envelope.partition_key(envelope)
    }
  end
end
