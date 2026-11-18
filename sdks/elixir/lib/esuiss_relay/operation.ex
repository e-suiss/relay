defmodule EsuissRelay.Operation do
  @moduledoc """
  Description of one operation of the Relay server API, generated from the OpenAPI contract.

  `query` lists the query parameters as `{name, kind, required?}`; `idempotency` and `if_match`
  say whether the operation takes those headers; `paginated` marks the cursor lists whose
  result is an `EsuissRelay.Page`.
  """

  @type query_kind :: :string | :integer | :boolean | :string_array
  @type requirement :: :required | :optional | :none

  @type t :: %__MODULE__{
          id: atom(),
          method: :get | :post | :put | :patch | :delete,
          path: String.t(),
          path_params: [atom()],
          query: [{atom(), query_kind(), boolean()}],
          idempotency: requirement(),
          if_match: requirement(),
          body: requirement(),
          content_type: String.t() | nil,
          paginated: boolean(),
          response: :json | :text | :none
        }

  @enforce_keys [:id, :method, :path]
  defstruct [
    :id,
    :method,
    :path,
    :content_type,
    path_params: [],
    query: [],
    idempotency: :none,
    if_match: :none,
    body: :none,
    paginated: false,
    response: :json
  ]
end
