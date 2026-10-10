defmodule Relay do
  @moduledoc """
  Relay is the notification, messaging and event orchestration platform of Suiss. This module is the shared kernel boundary: the ports, types and runtime helpers every context may use.
  """

  use Boundary,
    deps: [],
    exports: [Clock, Random, Error, Redacted, Decision, Process, Config, Role, Repo, LogRedactor]
end
