defmodule EsuissRelay.AuthenticationError do
  @moduledoc "The credentials were missing, refused or lack the scope (family `auth`)."
  use EsuissRelay.Error, :authentication
end

defmodule EsuissRelay.ValidationError do
  @moduledoc "The request was malformed or failed validation (400, 413, 415, 422)."
  use EsuissRelay.Error, :validation
end

defmodule EsuissRelay.RateLimitError do
  @moduledoc "The rate limit was reached (429 `rate_limited`); retried after `Retry-After`."
  use EsuissRelay.Error, :rate_limit
end

defmodule EsuissRelay.QuotaError do
  @moduledoc "The sending quota is exhausted (429 `quota_exhausted`); never retried."
  use EsuissRelay.Error, :quota
end

defmodule EsuissRelay.IdempotencyError do
  @moduledoc "The `Idempotency-Key` was missing, invalid, reused or still in progress."
  use EsuissRelay.Error, :idempotency
end

defmodule EsuissRelay.ServerError do
  @moduledoc "Relay failed or is unavailable (5xx)."
  use EsuissRelay.Error, :server
end

defmodule EsuissRelay.NotFoundError do
  @moduledoc "The resource does not exist in this tenant and environment (404)."
  use EsuissRelay.Error, :not_found
end

defmodule EsuissRelay.ConflictError do
  @moduledoc "The request conflicts with the state of the resource (409, 412, 428)."
  use EsuissRelay.Error, :conflict
end

defmodule EsuissRelay.ApiError do
  @moduledoc "Any other error answer of Relay."
  use EsuissRelay.Error, :api
end

defmodule EsuissRelay.ConnectionError do
  @moduledoc "No answer arrived from Relay; `reason` holds the transport error."
  use EsuissRelay.Error, :connection
end
