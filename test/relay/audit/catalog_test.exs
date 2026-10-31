defmodule Relay.Audit.CatalogTest do
  use Relay.SqlCase, async: false

  @events Path.expand("../../../contracts/asyncapi/events.yaml", __DIR__)
  @lib Path.expand("../../../lib", __DIR__)
  @action ~r/'([a-z][a-z0-9_]*\.[a-z][a-z0-9_]*)'/

  @writers """
  SELECT n.nspname || '.' || p.proname, p.prosrc
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname IN ('relay_fn', 'relay_ops', 'relay_private')
    AND p.prosrc LIKE '%audit_write(%'
  ORDER BY 1
  """

  defp catalog do
    doc = YamlElixir.read_from_file!(@events)

    for {key, _ref} <- doc["channels"]["auditLog"]["messages"],
        into: MapSet.new(),
        do: doc["components"]["messages"][key]["name"]
  end

  defp arguments(text), do: split(String.to_charlist(text), 0, false, [], [])

  defp split([?) | _rest], 0, false, current, acc), do: Enum.reverse([chars(current) | acc])

  defp split([?' | rest], depth, quoted, current, acc),
    do: split(rest, depth, not quoted, [?' | current], acc)

  defp split([?, | rest], 0, false, current, acc),
    do: split(rest, 0, false, [], [chars(current) | acc])

  defp split([?( | rest], depth, false, current, acc),
    do: split(rest, depth + 1, false, [?( | current], acc)

  defp split([?) | rest], depth, false, current, acc),
    do: split(rest, depth - 1, false, [?) | current], acc)

  defp split([char | rest], depth, quoted, current, acc),
    do: split(rest, depth, quoted, [char | current], acc)

  defp chars(current), do: current |> Enum.reverse() |> List.to_string() |> String.trim()

  defp literals(text), do: for([_, action] <- Regex.scan(@action, text), do: action)

  defp actions(name, body) do
    for call <- body |> String.split("audit_write(") |> tl() do
      expression = call |> arguments() |> Enum.at(2)

      found =
        case literals(expression) do
          [] ->
            assert expression =~ ~r/^[a-z_]+$/, "#{name}: #{expression}"
            [_, assigned] = Regex.run(~r/#{expression}\s*:=(.*?);/s, body)
            literals(assigned)

          found ->
            found
        end

      assert found != [], "#{name}: #{expression}"
      found
    end
  end

  defp database_actions do
    for [name, body] <- rows(@writers),
        action <- List.flatten(actions(name, body)),
        into: MapSet.new(),
        do: action
  end

  defp code_actions do
    for file <- Path.wildcard(Path.join(@lib, "**/*.ex")),
        [_, action] <- Regex.scan(~r/\baction: "([a-z_]+\.[a-z_]+)"/, File.read!(file)),
        into: MapSet.new(),
        do: action
  end

  describe "TN-47 API-3 audit catalog" do
    test "TN-47, API-3: every audit action the database writes is in the event catalog" do
      written = database_actions()
      assert MapSet.size(written) > 0
      assert MapSet.difference(written, catalog()) == MapSet.new()
    end

    test "TN-47, API-3: every audit action the code writes is in the event catalog" do
      written = code_actions()
      assert MapSet.size(written) > 0
      assert MapSet.difference(written, catalog()) == MapSet.new()
    end

    test "TN-47, API-3: every audit action of the catalog is written by the database or the code" do
      written = MapSet.union(database_actions(), code_actions())
      assert MapSet.difference(catalog(), written) == MapSet.new()
    end
  end
end
