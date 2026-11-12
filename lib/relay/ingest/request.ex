defmodule Relay.Ingest.Request do
  @moduledoc """
  The checks of a send request that the body schema cannot express (API-20 … API-26, API-62), as a pure function of the request, the workflow version it resolves to, the environment and the time. Field errors are all reported at once (API-37); the request's own fields never change the lane, and a policy outcome is never an error here.

  * `data` is at most the contract's `event.max_data_bytes`; `send_at` lies in the future and at most `event.max_send_at_ahead` ahead (`Relay.Limits`); `expires_at` lies in the future and not before `send_at`.
  * `security_subtype` and `on_expire` belong to the `security` class; a subtype needs `expires_at` (API-24). `retention: none` is refused for `security` and together with an inbox step (API-26).
  * `priority` is clamped to the class ceiling with a `priority_clamped` warning (API-22); `channels` only narrows the workflow's steps.
  * Raw provider blocks cannot set policy fields (`422 policy_field_not_overridable`, API-23). The provider and `overrides.email.from` are checked against the verified routes by the send operation (`403 channel_not_configured`).
  * A per-request `send_mode` is accepted only in the test environment (`403 auth_environment_mismatch`, API-62, API-76).
  * A recipient is a plain identifier (it must exist), an object with only `id` (an inbox-only subscriber) or an object with contact details (an explicit upsert, API-21) or a topic (`{topic}`), which the send operation expands into its frozen subscribers (WF-52).
  * `timing: next_break` defers the send to the recipient's next break (WF-56, WF-57): it needs `max_defer`, a fixed-length duration above zero counted from `send_at` or now, whose instant may not pass `expires_at`; `max_defer` without `next_break` is refused. In the `security` class the field is ignored, the send is immediate and the answer warns `timing_ignored`.
  * The sender's `interruption` is kept as sent; the push policy lowers it at send time (CH-65, CH-84). Every `links` `href` is an absolute `https` URI (`422 link_scheme_not_allowed`) and every `rel` is unique in the request (E-83).
  """

  @data_bytes Relay.Limits.fetch!(["event", "max_data_bytes"])
  @horizon Relay.Limits.fetch!(["event", "max_send_at_ahead"])
  @horizon_s Relay.Limits.seconds!(["event", "max_send_at_ahead"])
  @ceilings %{"marketing" => "normal"}
  @rank %{"low" => 0, "normal" => 1, "high" => 2}
  @raw_channels ~w(push web_push whatsapp)
  @duration ~r/\AP(?!\z)(?:(\d+)W)?(?:(\d+)D)?(?:T(?=\d)(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?\z/
  @units [604_800, 86_400, 3_600, 60, 1]
  @policy_fields ~w(interruption_level interruption-level priority push_type push-type
                    apns-priority apns-push-type apns_priority apns_push_type critical
                    time_sensitive time-sensitive urgency importance)

  @type target ::
          {:require, String.t()}
          | {:inbox_only, String.t()}
          | {:implicit, String.t(), map()}
          | {:topic, String.t()}
  @type step :: %{key: String.t(), channel: String.t(), template: String.t(), skip: term()}

  # API-20
  # API-21
  # API-22
  # API-23
  # API-24
  # API-26
  # API-62
  # E-83
  # WF-56
  @doc "Checks a decoded send request against its workflow version (`message_class`, `steps`), the `environment`, `now` and whether the credential is an agent's (`agent`, PC-57 (7)); returns the normalised request or the first failing rule's error."
  @spec check(map(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def check(
        body,
        %{message_class: class, steps: steps, environment: environment, now: now} = ctx
      ) do
    with :ok <- send_mode(body, environment),
         :ok <- policy_fields(body),
         :ok <- link_schemes(Map.get(body, "links", [])),
         {:ok, times} <- times(body, now) do
      {priority, warnings} = priority(Map.get(body, "priority", "normal"), class)
      narrowed = narrow(steps, Map.get(body, "channels"))
      {timing, timing_errors} = timing(body, class, times, now)

      errors =
        data_errors(body) ++
          class_errors(body, class, times) ++
          retention_errors(body, class, narrowed) ++
          rel_errors(Map.get(body, "links", [])) ++ timing_errors

      if errors == [] do
        {:ok,
         Map.merge(times, %{
           timing: timing.timing,
           max_defer_until: timing.max_defer_until,
           targets: Enum.map(Map.get(body, "to", []), &target/1),
           priority: priority,
           warnings: warnings ++ timing.warnings,
           sender_type: sender_type(body, ctx),
           actor: Map.get(body, "actor"),
           tenant: Map.get(body, "tenant"),
           dedup_key: Map.get(body, "dedup_key"),
           security_subtype: Map.get(body, "security_subtype"),
           on_expire: Map.get(body, "on_expire"),
           timing_precision: Map.get(body, "timing_precision"),
           cancellation_key: Map.get(body, "cancellation_key"),
           retention_none: Map.get(body, "retention") == "none",
           metadata: Map.get(body, "metadata"),
           data: Map.get(body, "data", %{}),
           send_mode: Map.get(body, "send_mode"),
           overrides: Map.get(body, "overrides", %{}),
           interruption: Map.get(body, "interruption"),
           links: Map.get(body, "links"),
           correlation_id: Map.get(body, "correlation_id"),
           item: Map.get(body, "item"),
           steps: Enum.map(narrowed, &subtype_rule(&1, Map.get(body, "security_subtype")))
         })}
      else
        {:error,
         Relay.Error.new(:validation_failed, "the request breaks a field rule", %{
           errors: Enum.sort_by(errors, & &1.pointer)
         })}
      end
    end
  end

  # PC-57 (7)
  defp sender_type(_body, %{agent: true}), do: "agent"
  defp sender_type(body, _ctx), do: get_in(body, ["actor", "type"]) || "system"

  # API-62
  # API-76
  defp send_mode(%{"send_mode" => _mode}, :live) do
    {:error, Relay.Error.new(:auth_environment_mismatch, "a per-request send mode is test only")}
  end

  defp send_mode(_body, _environment), do: :ok

  # API-23
  defp policy_fields(body) do
    case policy_field_errors(Map.get(body, "overrides"), "/overrides") do
      [] ->
        :ok

      errors ->
        {:error,
         Relay.Error.new(:policy_field_not_overridable, "raw blocks cannot set policy fields", %{
           errors: errors
         })}
    end
  end

  # API-23
  @doc "The field errors of the policy fields a channel-keyed overrides map sets in a raw provider block, with pointers under `prefix` (such as `/overrides` of a request or `/definition/steps/0/overrides` of a workflow); a raw block never sets a policy field."
  @spec policy_field_errors(map() | nil, String.t()) :: [map()]
  def policy_field_errors(%{} = overrides, prefix) do
    for channel <- @raw_channels,
        raw = get_in(overrides, [channel, "raw"]),
        is_map(raw),
        {key, _value} <- raw,
        String.downcase(key) in @policy_fields,
        do: field("#{prefix}/#{channel}/raw/#{key}", "not_allowed", "a policy field")
  end

  def policy_field_errors(_overrides, _prefix), do: []

  # E-83
  defp link_schemes(links) do
    found =
      for {%{"href" => href}, index} <- Enum.with_index(links),
          not https?(href),
          do: field("/links/#{index}/href", "unsupported_value", "an absolute https URI")

    case found do
      [] ->
        :ok

      errors ->
        {:error,
         Relay.Error.new(:link_scheme_not_allowed, "a link is not an absolute https URI", %{
           errors: errors
         })}
    end
  end

  defp https?(href) when is_binary(href) do
    case URI.parse(href) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> true
      _other -> false
    end
  end

  defp https?(_href), do: false

  # E-83
  defp rel_errors(links) do
    links
    |> Enum.with_index()
    |> Enum.reduce({MapSet.new(), []}, fn {link, index}, {seen, errors} ->
      rel = link["rel"]

      if MapSet.member?(seen, rel),
        do: {seen, errors ++ [field("/links/#{index}/rel", "conflict", "rel is unique")]},
        else: {MapSet.put(seen, rel), errors}
    end)
    |> elem(1)
  end

  defp times(body, now) do
    with {:ok, send_at} <- time(body, "send_at"),
         {:ok, expires_at} <- time(body, "expires_at") do
      errors =
        future("/send_at", send_at, now, true) ++
          future("/expires_at", expires_at, now, false) ++ order(send_at, expires_at)

      if errors == [],
        do: {:ok, %{send_at: send_at, expires_at: expires_at}},
        else: failed(errors)
    end
  end

  defp time(body, name) do
    case Map.get(body, name) do
      nil ->
        {:ok, nil}

      text when is_binary(text) ->
        case DateTime.from_iso8601(text) do
          {:ok, at, _offset} -> {:ok, at}
          {:error, _reason} -> failed([field("/" <> name, "invalid_format", "RFC 3339 time")])
        end
    end
  end

  defp future(_pointer, nil, _now, _bounded), do: []

  defp future(pointer, at, now, bounded) do
    cond do
      DateTime.compare(at, now) != :gt ->
        [field(pointer, "too_short", "the time must be in the future")]

      bounded and DateTime.diff(at, now) > @horizon_s ->
        [field(pointer, "too_long", "the time is at most #{@horizon} ahead")]

      true ->
        []
    end
  end

  defp order(%DateTime{} = send_at, %DateTime{} = expires_at) do
    if DateTime.compare(expires_at, send_at) == :gt,
      do: [],
      else: [field("/expires_at", "conflict", "expires_at comes after send_at")]
  end

  defp order(_send_at, _expires_at), do: []

  # WF-56
  # WF-57
  # E-77
  defp timing(%{"timing" => "next_break"}, "security", _times, _now) do
    warning = %{
      "code" => "timing_ignored",
      "pointer" => "/timing",
      "detail" => "the security class is sent at once"
    }

    {%{timing: nil, max_defer_until: nil, warnings: [warning]}, []}
  end

  defp timing(%{"timing" => "next_break"} = body, _class, times, now) do
    base = times.send_at || now

    case duration_s(Map.get(body, "max_defer")) do
      nil ->
        {none(), [field("/max_defer", "required", "timing next_break needs max_defer")]}

      :error ->
        {none(), [field("/max_defer", "invalid_format", "a fixed-length ISO 8601 duration")]}

      0 ->
        {none(), [field("/max_defer", "too_short", "max_defer is above zero")]}

      seconds ->
        until = DateTime.add(base, seconds, :second)
        {%{timing: "next_break", max_defer_until: until, warnings: []}, within(until, times)}
    end
  end

  defp timing(body, _class, _times, _now) do
    if Map.has_key?(body, "max_defer"),
      do: {none(), [field("/max_defer", "not_allowed", "only timing next_break has max_defer")]},
      else: {none(), []}
  end

  defp none, do: %{timing: nil, max_defer_until: nil, warnings: []}

  defp within(until, %{expires_at: %DateTime{} = expires_at}) do
    if DateTime.compare(until, expires_at) == :gt,
      do: [field("/max_defer", "conflict", "max_defer cannot pass expires_at")],
      else: []
  end

  defp within(_until, _times), do: []

  defp duration_s(nil), do: nil

  defp duration_s(text) when is_binary(text) do
    case Regex.run(@duration, text) do
      [_ | parts] ->
        parts
        |> Kernel.++(List.duplicate("", length(@units) - length(parts)))
        |> Enum.zip(@units)
        |> Enum.reduce(0, fn
          {"", _unit}, acc -> acc
          {digits, unit}, acc -> acc + String.to_integer(digits) * unit
        end)

      nil ->
        :error
    end
  end

  defp duration_s(_text), do: :error

  # API-22
  defp priority(requested, class) do
    ceiling = Map.get(@ceilings, class, "high")

    if @rank[requested] > @rank[ceiling] do
      detail = "the class allows at most #{ceiling}"
      {ceiling, [%{"code" => "priority_clamped", "pointer" => "/priority", "detail" => detail}]}
    else
      {requested, []}
    end
  end

  defp narrow(steps, nil), do: steps
  defp narrow(steps, channels), do: Enum.filter(steps, &(&1.channel in channels))

  defp data_errors(body) do
    if byte_size(Jason.encode!(Map.get(body, "data", %{}))) > @data_bytes,
      do: [field("/data", "too_long", "data is at most #{@data_bytes} bytes")],
      else: []
  end

  # API-24
  defp class_errors(body, class, times) do
    subtype = Map.get(body, "security_subtype")

    [
      {subtype != nil and class != "security",
       field("/security_subtype", "not_allowed", "only the security class has subtypes")},
      {subtype != nil and times.expires_at == nil,
       field("/expires_at", "required", "a security subtype needs expires_at")},
      {Map.has_key?(body, "on_expire") and class != "security",
       field("/on_expire", "not_allowed", "only the security class has on_expire")}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  # API-26
  defp retention_errors(%{"retention" => "none"}, class, steps) do
    cond do
      class == "security" ->
        [field("/retention", "not_allowed", "the security class never stores content")]

      Enum.any?(steps, &(&1.channel == "in_app")) ->
        [field("/retention", "conflict", "retention none is refused with an inbox step")]

      true ->
        []
    end
  end

  defp retention_errors(_body, _class, _steps), do: []

  # API-21
  # WF-51
  @doc "Classifies one recipient target of a send request."
  @spec target(String.t() | map()) :: target()
  def target(id) when is_binary(id), do: {:require, id}
  def target(%{"topic" => key}) when is_binary(key), do: {:topic, key}
  def target(%{"id" => id} = object) when map_size(object) == 1, do: {:inbox_only, id}
  def target(%{"id" => id} = object), do: {:implicit, id, Map.delete(object, "id")}

  # API-24
  defp subtype_rule(step, "otp_oob") when step.channel == "email",
    do: Map.put(step, :skip, {"otp_channel_forbidden", "channel_policy.otp_channel_forbidden"})

  defp subtype_rule(step, "email_verification") when step.channel != "email",
    do: Map.put(step, :skip, {"channel_policy", "channel_policy.email_verification_only"})

  defp subtype_rule(step, _subtype), do: Map.put(step, :skip, nil)

  defp failed(errors) do
    {:error,
     Relay.Error.new(:validation_failed, "the request breaks a field rule", %{errors: errors})}
  end

  defp field(pointer, code, detail), do: %{pointer: pointer, code: code, detail: detail}
end
