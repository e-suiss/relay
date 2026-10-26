defmodule Relay.Binary do
  @moduledoc """
  The refc binary playbook. A sub-binary taken from a large binary, such as a field matched out of an HTTP response body, keeps the whole parent alive for as long as it is held. Code that keeps such a part beyond the request (in process state, ETS or a long-lived message) passes it through `keep/1` at that retention boundary. Whole binaries are never copied wholesale.

  Diagnosis runs in this order: the memory breakdown (`:erlang.memory/0`), then binary memory per process (`Process.info(pid, :binary)`), then a targeted garbage collection of the suspected process.
  """

  # T-45
  @doc "Returns `binary` detached from its parent when it references more bytes than it holds; otherwise returns it unchanged."
  @spec keep(binary()) :: binary()
  def keep(binary) when is_binary(binary) do
    if :binary.referenced_byte_size(binary) > byte_size(binary),
      do: :binary.copy(binary),
      else: binary
  end
end
