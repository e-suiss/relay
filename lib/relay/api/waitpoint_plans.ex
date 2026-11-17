defmodule Relay.Api.WaitpointPlans do
  @moduledoc """
  The `escalation_policy` and `surface_policy` members of a waitpoint on the server API (AG-12, AG-17, AG-63). `prepare/2` turns the two members of a creation request into the plan attributes of `Relay.Agents.open_waitpoint_in/3`, outside any transaction; `refusal/2` is the error of a plan the waitpoint's responders do not fit; `escalation_view/1` and `surface_view/2` show the stored plan again.

  A surface policy orders only the interrupting deliveries of each responder it names: `in_app` is refused as a surface, since the inbox record is written at once. Its durations are the sender's; nothing here supplies one. A device is named by its `dev_` identifier and is not looked up at creation: a device that is not registered when its step comes is skipped then.
  """

  alias Relay.Api.Duration
  alias Relay.Api.EscalationPolicies
  alias Relay.Api.Responders
  alias Relay.Api.Views

  @min_after_ms 1_000
  @max_after_ms 2_592_000_000

  # AG-12
  # AG-17
  # AG-63
  @doc "Prepares the plan of a creation request outside any transaction: a map with `:escalation` and `:surface_policy` for the members the request carries, or `validation_failed` with every invalid field."
  @spec prepare(Relay.Scope.t(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def prepare(%Relay.Scope{} = scope, body) when is_map(body) do
    with {:ok, escalation} <- escalation(scope, body["escalation_policy"]),
         {:ok, surface} <- surface(scope, body["surface_policy"]) do
      plan = %{escalation: escalation, surface_policy: surface}
      {:ok, Map.reject(plan, fn {_member, value} -> value == nil end)}
    end
  end

  defp escalation(_scope, nil), do: {:ok, nil}

  defp escalation(_scope, %{"key" => key} = reference),
    do: {:ok, %{key: key, version: reference["version"]}}

  defp escalation(scope, %{"tiers" => tiers}) do
    pointer = "/escalation_policy/tiers"

    with {:ok, stored, _names} <- EscalationPolicies.tiers(scope, tiers, pointer),
         do: {:ok, %{tiers: stored}}
  end

  defp surface(_scope, nil), do: {:ok, nil}

  defp surface(scope, %{"recipients" => recipients}) do
    references = Enum.map(recipients, & &1["responder"])

    with {:ok, resolved} <- Responders.resolve(scope, references) do
      read = recipients |> Enum.with_index() |> Enum.map(&recipient(&1, resolved))
      repeated = repeated(recipients)

      case Enum.flat_map(read, &elem(&1, 1)) ++ repeated do
        [] -> {:ok, Enum.map(read, &elem(&1, 0))}
        errors -> {:error, invalid(errors)}
      end
    end
  end

  defp repeated(recipients) do
    recipients
    |> Enum.with_index()
    |> Enum.group_by(fn {entry, _index} -> entry["responder"] end, &elem(&1, 1))
    |> Enum.flat_map(fn {_responder, [_first | rest]} -> rest end)
    |> Enum.sort()
    |> Enum.map(&error("#{at(&1)}/responder", "conflict", "a responder has one surface policy"))
  end

  defp at(index), do: "/surface_policy/recipients/#{index}"

  defp recipient({entry, index}, resolved) do
    responder = entry["responder"]

    {steps, step_errors} =
      entry["steps"]
      |> Enum.with_index()
      |> Enum.map(&step(&1, "#{at(index)}/steps"))
      |> Enum.unzip()

    case Map.get(resolved, responder) do
      nil ->
        missing = error("#{at(index)}/responder", "not_found", "no such responder")
        {nil, [missing | List.flatten(step_errors)]}

      id ->
        stored = %{
          "recipient_id" => Relay.Id.to_string(id),
          "kind" => responder["kind"],
          "steps" => steps
        }

        {stored, List.flatten(step_errors)}
    end
  end

  defp step({step, index}, pointer) do
    at = "#{pointer}/#{index}"
    {after_ms, after_errors} = after_ms(step["escalate_after"], at <> "/escalate_after")

    {surfaces, surface_errors} =
      step["surfaces"]
      |> Enum.with_index()
      |> Enum.map(&target(&1, at <> "/surfaces"))
      |> Enum.unzip()

    stored = %{"surfaces" => surfaces, "escalate_after_ms" => after_ms}
    {stored, after_errors ++ List.flatten(surface_errors)}
  end

  defp after_ms(text, at) do
    case Duration.to_ms(text) do
      {:ok, ms} when ms < @min_after_ms ->
        {nil, [error(at, "too_short", "a step waits at least one second")]}

      {:ok, ms} when ms > @max_after_ms ->
        {nil, [error(at, "too_long", "a step waits at most thirty days")]}

      {:ok, ms} ->
        {ms, []}

      :error ->
        {nil, [error(at, "invalid_format", "not a duration of fixed length")]}
    end
  end

  defp target({%{"channel" => "in_app"}, index}, pointer) do
    detail = "the inbox record is written at once; a step orders only interrupting surfaces"
    {nil, [error("#{pointer}/#{index}/channel", "not_allowed", detail)]}
  end

  defp target({%{"channel" => channel}, _index}, _pointer), do: {%{"channel" => channel}, []}

  defp target({%{"device_id" => text}, index}, pointer) do
    case Relay.ExternalId.decode(text, ["dev"]) do
      {:ok, id} ->
        {%{"device_id" => Relay.Id.to_string(id)}, []}

      {:error, _error} ->
        at = "#{pointer}/#{index}/device_id"
        {nil, [error(at, "invalid_format", "not a device identifier")]}
    end
  end

  # AG-12
  # AG-53
  @doc "The error of a plan that `Relay.Agents.open_waitpoint_in/3` refused with `result`; `plan` is what `prepare/2` returned."
  @spec refusal(atom(), map()) :: Relay.Error.t()
  def refusal(:escalation_policy_not_found, _plan), do: EscalationPolicies.not_found()
  def refusal(:escalation_policy_archived, _plan), do: EscalationPolicies.archived()

  def refusal(:escalation_responder_outside_set, _plan) do
    message = "an escalation tier adds a responder that is not in responders"
    Relay.Error.new(:escalation_responder_outside_set, message)
  end

  def refusal(:escalation_tier_limit, plan) do
    case plan do
      %{escalation: %{tiers: tiers}} ->
        EscalationPolicies.too_many(length(tiers), "/escalation_policy/tiers")

      _stored ->
        %{limit: limit} = Relay.Agents.escalation_tier_limit()
        EscalationPolicies.too_many(limit + 1, "/escalation_policy")
    end
  end

  def refusal(:surface_recipient_outside_set, _plan) do
    detail = "a surface policy names only responders of the waitpoint"
    invalid([error("/surface_policy/recipients", "not_allowed", detail)])
  end

  # AG-17
  @doc "The `escalation_policy` member of a waitpoint from its stored policy reference: the pinned key and version, or the inline definition's anonymous version; `nil` without one."
  @spec escalation_view(String.t() | nil) :: map() | nil
  def escalation_view(nil), do: nil
  def escalation_view("inline"), do: %{"key" => nil, "version" => 1, "inline" => true}

  def escalation_view(reference) when is_binary(reference) do
    [key, version] = String.split(reference, ":", parts: 2)
    %{"key" => key, "version" => String.to_integer(version), "inline" => false}
  end

  # AG-63
  @doc "The `surface_policy` member of a waitpoint from its stored form, read outside any transaction; `nil` without one. A responder that has no name any more is left out."
  @spec surface_view(Relay.Scope.t(), [map()] | nil) ::
          {:ok, map() | nil} | {:error, Relay.Error.t()}
  def surface_view(_scope, nil), do: {:ok, nil}

  def surface_view(%Relay.Scope{} = scope, stored) when is_list(stored) do
    references = Enum.map(stored, &%{"kind" => &1["kind"], "id" => &1["recipient_id"]})

    with {:ok, names} <- Responders.read_names(scope, references) do
      recipients =
        for {entry, reference} <- Enum.zip(stored, references),
            responder = Responders.view(reference, names),
            responder != nil,
            do: %{"responder" => responder, "steps" => Enum.map(entry["steps"], &step_view/1)}

      {:ok, %{"recipients" => recipients}}
    end
  end

  defp step_view(step) do
    seconds = div(step["escalate_after_ms"], 1_000)

    %{
      "surfaces" => Enum.map(step["surfaces"], &target_view/1),
      "escalate_after" => Duration.iso(%Postgrex.Interval{months: 0, days: 0, secs: seconds})
    }
  end

  defp target_view(%{"channel" => channel}), do: %{"channel" => channel}

  defp target_view(%{"device_id" => text}) do
    {:ok, id} = Relay.Id.parse(text)
    %{"device_id" => Views.id("dev", id)}
  end

  defp error(pointer, code, detail), do: %{pointer: pointer, code: code, detail: detail}

  defp invalid(errors),
    do: Relay.Error.new(:validation_failed, "the waitpoint plan is invalid", %{errors: errors})
end
