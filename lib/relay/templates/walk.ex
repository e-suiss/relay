defmodule Relay.Templates.Walk do
  @moduledoc """
  Static reads of a parsed template for the dictionary lints and the ICU check of the publication gate: the fixed text a template prints (text nodes, `raw` blocks and string literals it outputs or assigns, ICU messages included) and the ICU messages it formats with the `icu` filter, whether given as a string literal or as a variable captured or assigned from fixed text earlier in the template (TP-21, TP-54, TP-59).
  """

  alias Relay.Templates.Engine
  alias Relay.Templates.Filters
  alias Solid.Tags

  # TP-21
  # TP-54
  @doc "The fixed texts of a parsed template, in source order."
  @spec texts(Engine.t()) :: [String.t()]
  def texts(%Engine{tree: tree}), do: tree |> collect(&text/1) |> Enum.reject(&(&1 == ""))

  defp collect(entries, fun) when is_list(entries), do: Enum.flat_map(entries, &collect(&1, fun))

  defp collect(%Tags.IfTag{} = tag, fun) do
    elsifs = Enum.flat_map(tag.elsifs, fn {_condition, body} -> collect(body, fun) end)
    collect(tag.body, fun) ++ elsifs ++ collect(tag.else_body || [], fun)
  end

  defp collect(%Tags.CaseTag{cases: cases}, fun),
    do: Enum.flat_map(cases, fn {_values, body} -> collect(body, fun) end)

  defp collect(%Tags.ForTag{} = tag, fun),
    do: collect(tag.body, fun) ++ collect(tag.else_body || [], fun)

  defp collect(%Tags.CaptureTag{body: body}, fun), do: collect(body, fun)
  defp collect(%Tags.AssignTag{object: object}, fun), do: fun.(object)
  defp collect(entry, fun), do: fun.(entry)

  defp text(%Solid.Text{text: text}) when is_binary(text), do: [text]
  defp text(%Tags.RawTag{text: text}) when is_binary(text), do: [text]

  defp text(%Solid.Object{argument: %Solid.Literal{value: value}}) when is_binary(value),
    do: [value]

  defp text(_entry), do: []

  # TP-59
  @doc "The ICU messages a parsed template formats with `icu`, in source order."
  @spec icu_messages(Engine.t()) :: [String.t()]
  def icu_messages(%Engine{tree: tree}) do
    {messages, _env} = icu(tree, {[], %{}})
    Enum.reverse(messages)
  end

  defp icu(entries, state) when is_list(entries), do: Enum.reduce(entries, state, &icu/2)

  defp icu(%Tags.IfTag{} = tag, state) do
    state = icu(tag.body, state)
    state = Enum.reduce(tag.elsifs, state, fn {_condition, body}, state -> icu(body, state) end)
    icu(tag.else_body || [], state)
  end

  defp icu(%Tags.CaseTag{cases: cases}, state),
    do: Enum.reduce(cases, state, fn {_values, body}, state -> icu(body, state) end)

  defp icu(%Tags.ForTag{} = tag, state), do: icu(tag.else_body || [], icu(tag.body, state))

  defp icu(%Tags.CaptureTag{argument: target, body: body}, state) do
    {messages, env} = icu(body, state)

    case fixed(body) do
      nil -> {messages, env}
      text -> {messages, Map.put(env, name(target), text)}
    end
  end

  defp icu(%Tags.AssignTag{argument: target, object: object}, state) do
    {messages, env} = icu(object, state)

    case object do
      %Solid.Object{argument: %Solid.Literal{value: value}, filters: []} when is_binary(value) ->
        {messages, Map.put(env, name(target), value)}

      _other ->
        {messages, Map.delete(env, name(target))}
    end
  end

  defp icu(%Solid.Object{argument: argument, filters: filters}, {messages, env}) do
    case {first_filter(filters), argument} do
      {"icu", %Solid.Literal{value: value}} when is_binary(value) ->
        {[value | messages], env}

      {"icu", %Solid.Variable{identifier: id, accesses: []}} when is_map_key(env, id) ->
        {[Map.fetch!(env, id) | messages], env}

      _other ->
        {messages, env}
    end
  end

  defp icu(_entry, state), do: state

  defp fixed(body) do
    if Enum.all?(body, &match?(%Solid.Text{}, &1)), do: Enum.map_join(body, & &1.text)
  end

  defp name(%Solid.Variable{identifier: id}) when is_binary(id), do: id
  defp name(other), do: to_string(other)

  defp first_filter(filters) do
    filters
    |> Enum.reject(&(&1.function == Filters.output_filter()))
    |> List.first()
    |> case do
      %Solid.Filter{function: name} -> name
      nil -> nil
    end
  end
end
