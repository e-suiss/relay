defmodule Relay.Workflow.Throttle do
  @moduledoc """
  The throttle step (WF-32): an exact counter per tenant-wide key in PostgreSQL, so workflows that use the same key throttle together. A key's counter opens its window at the first counted event (`window`, `until`) or on the recipient's calendar day or week (`calendar`), counts at most `limit` events and answers `:limited` for the rest, which the run records as `skipped` with `rule_id = throttle.limited`; an event is counted once by its reference, so a retried step answers its first outcome. An active counter is reset through the API, audited (API-69). A window is at most 31 days (WF-37). The key is stored as a digest only.

  Throttle is not the frequency cap (a category × channel policy of the lattice, §13) and not the send rate of a campaign or channel; the three are set apart and never stand in for each other (WF-33). The density threshold of digests (WF-30) counts on the same counters under its own key space.
  """

  alias Relay.Actor
  alias Relay.Scope
  alias Relay.Workflow.Throttle.Store
  alias Relay.Workflow.Throttle.Window

  @rule "throttle.limited"

  @type hit :: %{
          outcome: :allowed | :limited,
          rule_id: String.t() | nil,
          count: non_neg_integer() | nil,
          limit: pos_integer(),
          window_end: DateTime.t() | nil,
          repeated: boolean()
        }

  # WF-32
  @doc "The rule a throttled event is recorded with."
  @spec rule_id() :: String.t()
  def rule_id, do: @rule

  # WF-32
  # WF-59
  @doc "Checks the fields of a `throttle` step; see `Relay.Workflow.Throttle.Window.config/2`."
  @spec config(map(), String.t()) :: {:ok, Window.t()} | {:error, [Window.field_error(), ...]}
  defdelegate config(step, pointer \\ ""), to: Window

  # WF-32
  # WF-33
  # WF-37
  @doc """
  Counts an event against a throttle step inside the caller's scoped transaction. `step` holds the step fields; `attrs`: `:key` (the rendered tenant-wide key), `:ref` (a string unique to the event within the key, such as the notification and step key), optionally `:time_zone` (the recipient's zone, for a `calendar` window) and `:until` (the time an `until` pointer resolved to). An `until` already past counts nothing and allows the event.
  """
  @spec hit(Scope.t(), map(), map()) :: {:ok, hit()} | {:error, Relay.Error.t()}
  def hit(%Scope{} = scope, step, attrs) do
    with {:ok, config} <- step_config(step),
         :ok <- valid_key(attrs.key),
         {:ok, zone} <- zone(Map.get(attrs, :time_zone)) do
      now = Relay.Clock.business_now(scope)
      bounds = Window.bounds(config, now, zone, Map.get(attrs, :until))
      counted(bounds, key_digest(attrs.key), attrs.ref, config.limit)
    end
  end

  # WF-32
  @doc "Counts an event against a throttle step in its own scoped transaction; see `hit/3`."
  @spec hit_now(Scope.t(), map(), map()) :: {:ok, hit()} | {:error, term()}
  def hit_now(%Scope{} = scope, step, attrs) do
    case Store.in_scope(scope, fn _status -> hit(scope, step, attrs) end) do
      {:ok, {:ok, hit}} -> {:ok, hit}
      {:ok, {:error, error}} -> {:error, error}
      {:error, reason} -> {:error, reason}
    end
  end

  # WF-30
  @doc "Counts an event on a counter of its own key space inside the caller's scoped transaction: `{space, parts}` names it (parts are strings or `nil`), `ref` is the event's unique string and `threshold` holds the `limit` and the `window` duration."
  @spec count(Scope.t(), {String.t(), [String.t() | nil]}, String.t(), map()) ::
          {:ok, hit()} | {:error, Relay.Error.t()}
  def count(%Scope{} = scope, {space, parts}, ref, threshold) when is_binary(space) do
    texts = Enum.map(parts, &(&1 || ""))
    step = %{"key" => space, "limit" => threshold["limit"], "window" => threshold["window"]}

    case Window.config(step) do
      {:ok, config} ->
        bounds = Window.bounds(config, Relay.Clock.business_now(scope), nil)
        counted(bounds, space_digest(space, texts), ref, config.limit)

      {:error, errors} ->
        {:error, invalid(errors)}
    end
  end

  # WF-32
  # API-69
  @doc "Resets the active counter of a key inside the caller's scoped transaction, audited as `throttle.reset`."
  @spec reset(Scope.t(), String.t(), <<_::256>>, Actor.t()) ::
          {:ok, {:reset | :not_active, Relay.Id.t() | nil}} | {:error, Relay.Error.t()}
  def reset(%Scope{} = _scope, key, digest, %Actor{} = actor) do
    with :ok <- valid_key(key), do: {:ok, Store.reset(key_digest(key), digest, actor)}
  end

  # WF-32
  @doc "The digest a key is stored as: SHA-256 over the deterministic CBOR of the key."
  @spec key_digest(String.t()) :: <<_::256>>
  def key_digest(key) when is_binary(key), do: sha256(["relay.throttle_key.v1", key])

  defp space_digest(space, texts), do: sha256(["relay.throttle_space.v1", space | texts])

  defp counted(:passed, _key_digest, _ref, limit), do: {:ok, passed(limit)}

  defp counted({:error, reason}, _key_digest, _ref, _limit) do
    message = "the throttle window is not valid: #{reason}"
    {:error, Relay.Error.new(:validation_failed, message)}
  end

  defp counted(bounds, key_digest, ref, limit) when is_binary(ref) do
    hit = Store.hit(key_digest, sha256(["relay.throttle_hit.v1", ref]), limit, bounds)
    rule = if hit.outcome == :limited, do: @rule

    {:ok, hit |> Map.merge(%{rule_id: rule, limit: limit}) |> Map.delete(:counter_id)}
  end

  defp passed(limit) do
    %{
      outcome: :allowed,
      rule_id: nil,
      count: nil,
      limit: limit,
      window_end: nil,
      repeated: false
    }
  end

  defp step_config(%{key: _key, limit: _limit, window: _window} = config), do: {:ok, config}

  defp step_config(step) when is_map(step) do
    case Window.config(Map.put_new(step, "key", "-")) do
      {:ok, config} -> {:ok, config}
      {:error, errors} -> {:error, invalid(errors)}
    end
  end

  defp valid_key(key) do
    if Window.key?(key),
      do: :ok,
      else: {:error, Relay.Error.new(:validation_failed, "the throttle key is not valid")}
  end

  defp zone(nil), do: {:ok, nil}

  defp zone(zone), do: Relay.TimeZone.new(zone)

  defp sha256(parts), do: :crypto.hash(:sha256, Relay.Canonical.encode!(parts))

  defp invalid(errors) do
    details = Enum.map(errors, &stringify/1)
    Relay.Error.new(:validation_failed, "the throttle step is not valid", %{errors: details})
  end

  defp stringify(error), do: Map.new(error, fn {key, value} -> {Atom.to_string(key), value} end)
end
