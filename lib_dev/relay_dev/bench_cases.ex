defmodule RelayDev.BenchCases do
  @moduledoc "Hot path cases shared by the reduction gate and the nightly Benchee run (T-68)."

  @doc "Named zero-arity cases; each calls compiled code so reductions reflect the real path."
  @spec all() :: [{String.t(), (-> term())}]
  def all do
    [
      {"decision.skip", &decision_skip/0},
      {"log_redactor.scrub", &log_redactor_scrub/0}
    ]
  end

  @doc false
  @spec decision_skip() :: Relay.Decision.t()
  def decision_skip, do: Relay.Decision.skip(:quiet_hours, "PC-46")

  @doc false
  @spec log_redactor_scrub() :: term()
  def log_redactor_scrub do
    Relay.LogRedactor.scrub(%{
      recipient: Relay.Redacted.wrap("+905550000000"),
      items: [1, 2, %{token: Relay.Redacted.wrap("t")}]
    })
  end
end
