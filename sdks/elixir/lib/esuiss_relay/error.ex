defmodule EsuissRelay.Error do
  @moduledoc """
  The typed errors of the SDK.

  Every API error is an exception struct carrying the RFC 9457 problem details Relay returned:
  `status`, `code`, `title`, `detail`, `type`, `request_id`, `retryable`, `retry_after` (seconds)
  and the whole `problem` map. `category` is one of the five classes every Relay SDK shares:
  `:auth`, `:validation`, `:rate_limit`, `:idempotency`, `:server` (and `:connection` when no
  answer arrived). The class of a known code comes from its catalog family (`auth`, `quota` as
  rate limit, `idempotency`, `platform` as server; every other family is validation unless the
  status is 5xx); an unknown code is classed by its status. `class` names the exception:

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

  @type category :: :auth | :validation | :rate_limit | :idempotency | :server | :connection | :api

  @fields [
    :class,
    :category,
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
              category: EsuissRelay.Error.category() | nil,
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

  @family_categories %{
    "auth" => :auth,
    "quota" => :rate_limit,
    "idempotency" => :idempotency,
    "platform" => :server
  }

  # X-29
  # API-65
  @doc "The shared class of an error answer, from its status and problem code."
  @spec category(non_neg_integer(), String.t() | nil) ::
          :auth | :validation | :rate_limit | :idempotency | :server | :api
  def category(status, code) do
    case family(code) do
      nil -> by_status_category(status)
      family -> Map.get(@family_categories, family, if(status >= 500, do: :server, else: :validation))
    end
  end

  defp by_status_category(status) when status in [401, 403], do: :auth
  defp by_status_category(429), do: :rate_limit
  defp by_status_category(status) when status in 500..599, do: :server
  defp by_status_category(status) when status in 400..499, do: :validation
  defp by_status_category(_status), do: :api

  # X-29
  @doc "The exception class of an error answer, from its status and problem code."
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
    case category(status, code) do
      :auth -> :authentication
      :rate_limit -> rate_class(code)
      :idempotency -> :idempotency
      :server -> :server
      :validation -> validation_class(status)
      :api -> :api
    end
  end

  defp rate_class(code) do
    if code == nil or code == "rate_limited" or family(code) == nil,
      do: :rate_limit,
      else: :quota
  end

  defp validation_class(404), do: :not_found
  defp validation_class(status) when status in [409, 412, 428], do: :conflict
  defp validation_class(_status), do: :validation

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
  otherwise the error catalog entry of its code, otherwise the default of its status (a status
  outside the table is not retryable).
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

  # API-49
  @doc """
  Builds the typed error of an HTTP error answer as the transport returned it. `now` (Unix
  seconds) turns an HTTP-date `Retry-After` into seconds. `Retry-After` wins over the problem's
  `retry_after`; a value that is neither delta seconds nor an HTTP-date is ignored.
  """
  @spec from_transport(EsuissRelay.Transport.response(), integer()) :: t()
  def from_transport(%{status: status, headers: headers, body: body}, now) do
    problem = problem(body)
    from_response(status, header(headers, "request-id"), problem, retry_after(headers, problem, now))
  end

  @doc "Builds the typed error of an HTTP error answer from its parts."
  @spec from_response(non_neg_integer(), String.t() | nil, map(), non_neg_integer() | nil) :: t()
  def from_response(status, request_id, problem, retry_after) do
    code = if is_binary(problem["code"]), do: problem["code"]
    class = classify(status, code)

    struct(Map.fetch!(@modules, class),
      class: class,
      category: category(status, code),
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
  def connection(reason),
    do: struct(EsuissRelay.ConnectionError, reason: reason, category: :connection)

  defp problem(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, map} when is_map(map) -> map
      _other -> %{}
    end
  end

  defp problem(_body), do: %{}

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  defp retry_after(headers, problem, now) do
    with value when is_binary(value) <- header(headers, "retry-after"),
         seconds when is_integer(seconds) <- parse_retry_after(String.trim(value), now) do
      seconds
    else
      _absent -> body_retry_after(problem["retry_after"])
    end
  end

  defp body_retry_after(seconds) when is_integer(seconds) and seconds >= 0, do: seconds
  defp body_retry_after(_seconds), do: nil

  defp parse_retry_after(value, now) do
    if Regex.match?(~r/\A[0-9]+\z/, value),
      do: String.to_integer(value),
      else: http_date(value, now)
  end

  @unix_epoch 62_167_219_200

  defp http_date(value, now) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      {{_year, _month, _day}, {_hour, _minute, _second}} = datetime ->
        max(0, :calendar.datetime_to_gregorian_seconds(datetime) - @unix_epoch - now)

      _bad_date ->
        nil
    end
  end

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil
end
