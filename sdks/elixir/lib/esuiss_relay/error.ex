defmodule EsuissRelay.Error do
  @moduledoc """
  The typed errors of the SDK.

  Every API error is an exception struct carrying the RFC 9457 problem details Relay returned:
  `status`, `code`, `title`, `detail`, `type`, `request_id`, `retryable`, `retry_after` (seconds)
  and the whole `problem` map. `class` names the place of the error in the hierarchy:

    * `EsuissRelay.AuthenticationError` (`:authentication`)
    * `EsuissRelay.ValidationError` (`:validation`)
    * `EsuissRelay.RateLimitError` (`:rate_limit`) and `EsuissRelay.QuotaError` (`:quota`)
    * `EsuissRelay.IdempotencyError` (`:idempotency`)
    * `EsuissRelay.ServerError` (`:server`)
    * `EsuissRelay.NotFoundError` (`:not_found`), `EsuissRelay.ConflictError` (`:conflict`)
    * `EsuissRelay.ApiError` (`:api`) for every other answer
    * `EsuissRelay.ConnectionError` (`:connection`) when no answer arrived

  `rate_limit?/1` is true for both rate and quota errors.
  """

  alias EsuissRelay.Generated.ErrorCatalog

  @type class ::
          :authentication
          | :validation
          | :rate_limit
          | :quota
          | :idempotency
          | :server
          | :not_found
          | :conflict
          | :api
          | :connection

  @type t ::
          EsuissRelay.AuthenticationError.t()
          | EsuissRelay.ValidationError.t()
          | EsuissRelay.RateLimitError.t()
          | EsuissRelay.QuotaError.t()
          | EsuissRelay.IdempotencyError.t()
          | EsuissRelay.ServerError.t()
          | EsuissRelay.NotFoundError.t()
          | EsuissRelay.ConflictError.t()
          | EsuissRelay.ApiError.t()
          | EsuissRelay.ConnectionError.t()

  @fields [
    :class,
    :status,
    :code,
    :title,
    :detail,
    :type,
    :request_id,
    :retryable,
    :retry_after,
    :problem,
    :reason
  ]

  @doc false
  defmacro __using__(class) do
    quote do
      @type t :: %__MODULE__{
              class: EsuissRelay.Error.class(),
              status: non_neg_integer() | nil,
              code: String.t() | nil,
              title: String.t() | nil,
              detail: String.t() | nil,
              type: String.t() | nil,
              request_id: String.t() | nil,
              retryable: boolean(),
              retry_after: non_neg_integer() | nil,
              problem: map(),
              reason: term()
            }

      defexception Keyword.merge(Enum.map(unquote(@fields), &{&1, nil}),
                     class: unquote(class),
                     retryable: false,
                     problem: %{}
                   )

      @impl true
      def message(error), do: EsuissRelay.Error.describe(error)
    end
  end

  @doc "A one-line description of an error."
  @spec describe(t()) :: String.t()
  def describe(%{class: :connection, reason: reason}),
    do: "connection to Relay failed: " <> inspect(reason)

  def describe(error) do
    [error.status && "HTTP #{error.status}", error.code, error.title, error.detail]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  @doc "Whether an error is a rate or quota error."
  @spec rate_limit?(term()) :: boolean()
  def rate_limit?(%{class: class}) when class in [:rate_limit, :quota], do: true
  def rate_limit?(_error), do: false

  @modules %{
    authentication: EsuissRelay.AuthenticationError,
    validation: EsuissRelay.ValidationError,
    rate_limit: EsuissRelay.RateLimitError,
    quota: EsuissRelay.QuotaError,
    idempotency: EsuissRelay.IdempotencyError,
    server: EsuissRelay.ServerError,
    not_found: EsuissRelay.NotFoundError,
    conflict: EsuissRelay.ConflictError,
    api: EsuissRelay.ApiError,
    connection: EsuissRelay.ConnectionError
  }

  # X-29
  @doc "The class of an error answer, from its status and problem code."
  @spec classify(non_neg_integer(), String.t() | nil) ::
          :authentication
          | :validation
          | :rate_limit
          | :quota
          | :idempotency
          | :server
          | :not_found
          | :conflict
          | :api
  def classify(status, code) do
    family = family(code)

    cond do
      family == "idempotency" -> :idempotency
      status >= 500 -> :server
      status == 429 -> if code == "quota_exhausted", do: :quota, else: :rate_limit
      family == "auth" or status == 401 -> :authentication
      true -> by_status(status)
    end
  end

  defp by_status(status) when status in [400, 413, 415, 422], do: :validation
  defp by_status(404), do: :not_found
  defp by_status(status) when status in [409, 412, 428], do: :conflict
  defp by_status(_status), do: :api

  defp family(code) when is_binary(code) do
    case ErrorCatalog.lookup(code) do
      %{family: family} -> family
      nil -> nil
    end
  end

  defp family(_code), do: nil

  # API-38
  @doc """
  Whether an error answer may be retried: the problem's own `retryable` when it is a boolean,
  otherwise the error catalog entry of its code, otherwise the default of its status.
  """
  @spec retryable?(non_neg_integer(), map()) :: boolean()
  def retryable?(status, problem) do
    code = problem["code"]

    cond do
      is_boolean(problem["retryable"]) -> problem["retryable"]
      is_binary(code) and ErrorCatalog.lookup(code) != nil -> ErrorCatalog.lookup(code).retryable
      true -> ErrorCatalog.default_retryable(status, code)
    end
  end

  @doc "Builds the typed error of an HTTP error answer."
  @spec from_response(non_neg_integer(), String.t() | nil, map(), non_neg_integer() | nil) :: t()
  def from_response(status, request_id, problem, retry_after) do
    code = if is_binary(problem["code"]), do: problem["code"]
    class = classify(status, code)

    struct(Map.fetch!(@modules, class),
      class: class,
      status: status,
      code: code,
      title: string(problem["title"]),
      detail: string(problem["detail"]),
      type: string(problem["type"]),
      request_id: string(problem["request_id"]) || request_id,
      retryable: retryable?(status, problem),
      retry_after: retry_after,
      problem: problem
    )
  end

  @doc "Builds the error of a request that got no answer."
  @spec connection(term()) :: EsuissRelay.ConnectionError.t()
  def connection(reason), do: struct(EsuissRelay.ConnectionError, reason: reason)

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil
end
