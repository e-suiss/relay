defmodule Relay.CLI.ExitCode do
  @moduledoc """
  The exit codes of the `relay` command line tool. The table is stable; new codes are only added.

  | Code | Kind | Meaning |
  |---|---|---|
  | 0 | `:ok` | success |
  | 1 | `:unexpected` | unexpected error |
  | 2 | `:usage` | usage error: unknown command or option, missing configuration |
  | 3 | `:auth` | authentication or authorization (401, 403) |
  | 4 | `:not_found` | not found (404) |
  | 5 | `:invalid` | validation or conflict (400, 409, 412, 413, 415, 422, 428) |
  | 6 | `:rate_limited` | rate limit or quota (429) |
  | 7 | `:unavailable` | server or connection (5xx, network, timeout) |
  | 8 | `:not_confirmed` | a live-plane change was not confirmed |
  """

  @codes %{
    ok: 0,
    unexpected: 1,
    usage: 2,
    auth: 3,
    not_found: 4,
    invalid: 5,
    rate_limited: 6,
    unavailable: 7,
    not_confirmed: 8
  }

  @type t :: 0..8
  @type kind ::
          :ok
          | :unexpected
          | :usage
          | :auth
          | :not_found
          | :invalid
          | :rate_limited
          | :unavailable
          | :not_confirmed

  # X-42
  @doc "The exit code of a kind."
  @spec code(kind()) :: t()
  def code(kind), do: Map.fetch!(@codes, kind)

  # X-42
  @doc "The kind of an HTTP status."
  @spec for_status(integer()) ::
          :ok | :auth | :not_found | :invalid | :rate_limited | :unavailable | :unexpected
  def for_status(status) when status in 200..299, do: :ok
  def for_status(status) when status in [401, 403], do: :auth
  def for_status(404), do: :not_found
  def for_status(status) when status in [400, 409, 412, 413, 415, 422, 428], do: :invalid
  def for_status(429), do: :rate_limited
  def for_status(status) when status in 500..599, do: :unavailable
  def for_status(_status), do: :unexpected
end
