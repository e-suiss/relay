defmodule Relay.Platform.RateLimit.Scripts do
  @moduledoc """
  The Valkey side of the limiters: one atomic script per decision, on one tenant-prefixed key, reading time only through the server's `TIME` (T-11). Keys are `relay:t:<tenant>:<environment>:rl:<g|f|s|l>:<limit key>` for GCRA, fixed window, sliding counter and sliding log, and `relay:t:<tenant>:<environment>:<limit key>` for the dead man's bucket ring. A failed call is returned as an error, never as a decision.
  """

  alias Relay.Platform.Valkey
  alias Relay.Platform.Valkey.Key
  alias Relay.Platform.Valkey.Script

  @external_resource Script.path("gcra")
  @external_resource Script.path("window")
  @external_resource Script.path("rate_ring")
  @gcra Script.read!("gcra")
  @window Script.read!("window")
  @ring Script.read!("rate_ring")

  @gcra_codes %{0 => :allowed, 1 => :limited, 2 => :ceiling, 3 => :cost_exceeds_burst}
  @window_tags %{fixed_window: "f", sliding_counter: "s", sliding_log: "l"}

  # T-9
  @doc "The scripts this module runs, for `SCRIPT LOAD` at start."
  @spec scripts() :: [Script.t()]
  def scripts, do: [@gcra, @window, @ring]

  # T-20 (1)
  # T-11
  @doc "Runs `gcra.lua`; returns `{code, retry_after_us, tat_us, now_us}`."
  @spec gcra(Relay.Scope.t(), String.t(), map(), module()) ::
          {:ok, {atom(), non_neg_integer(), integer(), integer()}} | {:error, Relay.Error.t()}
  def gcra(scope, limit_key, p, adapter) do
    args = [p.emission_us, p.burst, p.cost, p.cap, p.limit, p.period_us, p.offset_us]

    with {:ok, key} <- key(scope, ["rl", "g"], limit_key),
         {:ok, [code, retry, tat, now | _]} <- Valkey.eval(@gcra, key, args, adapter),
         {:ok, code} <- Map.fetch(@gcra_codes, code) do
      {:ok, {code, retry, tat, now}}
    else
      {:error, %Relay.Error{}} = error -> error
      _ -> reply_error()
    end
  end

  # T-19
  @doc "Runs `window.lua` in its check mode; returns `{code, count_after, retry_after_ms}`."
  @spec window(Relay.Scope.t(), String.t(), atom(), map(), module()) ::
          {:ok, {:allowed | :limited, non_neg_integer(), non_neg_integer()}}
          | {:error, Relay.Error.t()}
  def window(scope, limit_key, algorithm, p, adapter) do
    tag = Map.fetch!(@window_tags, algorithm)
    args = ["check", tag, p.limit, p.window_ms, p.offset_ms, p.cost]

    with {:ok, key} <- key(scope, ["rl", tag], limit_key),
         {:ok, [code, count, retry]} when code in [0, 1] <-
           Valkey.eval(@window, key, args, adapter) do
      {:ok, {if(code == 0, do: :allowed, else: :limited), count, retry}}
    else
      {:error, %Relay.Error{}} = error -> error
      _ -> reply_error()
    end
  end

  # T-27
  @doc "Runs `window.lua` as a sliding counter without a limit (`incr` or `read`); returns the estimate."
  @spec counter(
          Relay.Scope.t(),
          String.t(),
          pos_integer(),
          :incr | :read,
          non_neg_integer(),
          module()
        ) ::
          {:ok, non_neg_integer()} | {:error, Relay.Error.t()}
  def counter(scope, limit_key, window_ms, op, by, adapter) do
    args = [Atom.to_string(op), "s", 1, window_ms, 0, by]

    with {:ok, key} <- key(scope, ["rl", "s"], limit_key),
         {:ok, [0, estimate, 0]} <- Valkey.eval(@window, key, args, adapter) do
      {:ok, estimate}
    else
      {:error, %Relay.Error{}} = error -> error
      _ -> reply_error()
    end
  end

  # TN-43
  @doc "Runs `rate_ring.lua`; returns `{current_sum, baseline_sum}`."
  @spec ring(
          Relay.Scope.t(),
          String.t(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          module()
        ) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, Relay.Error.t()}
  def ring(scope, limit_key, cost, current, baseline, adapter) do
    with {:ok, key} <- key(scope, [], limit_key),
         {:ok, [current_sum, baseline_sum]} <-
           Valkey.eval(@ring, key, [cost, current, baseline], adapter) do
      {:ok, {current_sum, baseline_sum}}
    else
      {:error, %Relay.Error{}} = error -> error
      _ -> reply_error()
    end
  end

  # TN-17
  @doc "The tenant-prefixed Valkey key of a limit key under `prefix`."
  @spec key(Relay.Scope.t(), [String.t()], String.t()) ::
          {:ok, Key.t()} | {:error, Relay.Error.t()}
  def key(%Relay.Scope{tenant_id: tenant_id, environment: environment}, prefix, limit_key) do
    Key.new(
      Relay.Id.to_string(tenant_id),
      Relay.Environment.dump(environment),
      prefix ++ String.split(limit_key, ":"),
      1
    )
  end

  defp reply_error, do: {:error, Relay.Error.new(:valkey_reply, "unexpected limiter reply")}
end
