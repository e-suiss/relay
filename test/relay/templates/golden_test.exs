defmodule Relay.Templates.GoldenTest do
  use ExUnit.Case, async: true

  alias Relay.Templates.Context
  alias Relay.Templates.Engine

  @root Path.expand("golden", __DIR__)
  @cases @root |> File.ls!() |> Enum.sort()
  @channels Map.new(Context.channels(), &{Atom.to_string(&1), &1})
  @parts %{"html" => :html, "subject" => :subject, "text" => :text, "body" => :body}

  for name <- @cases do
    @external_resource Path.join([@root, name, "template.liquid"])
    @external_resource Path.join([@root, name, "context.json"])

    test "TP-42: the golden render #{name} is unchanged" do
      assert_golden(unquote(name))
    end
  end

  defp assert_golden(name) do
    dir = Path.join(@root, name)
    fixture = dir |> Path.join("context.json") |> File.read!() |> Jason.decode!()
    {:ok, template} = dir |> Path.join("template.liquid") |> File.read!() |> Engine.parse()
    channel = Map.fetch!(@channels, fixture["channel"])

    {:ok, context} =
      Context.new(channel,
        locale: fixture["locale"],
        time_zone: fixture["time_zone"],
        part: Map.get(@parts, fixture["part"]),
        data: Map.get(fixture, "data", %{}),
        helpers: fixture |> Map.get("helpers", %{}) |> Map.new(&helper/1)
      )

    {:ok, output} = Engine.render(template, context, channel)
    expected_path = Path.join(dir, "expected.txt")

    case File.read(expected_path) do
      {:ok, expected} ->
        assert output == expected, "golden render #{name} differs: #{Base.encode64(output)}"

      {:error, :enoent} ->
        flunk("golden render #{name} is missing; output: #{Base.encode64(output)}")
    end
  end

  defp helper({name, %{"trusted" => value}}), do: {name, {:trusted, value}}
  defp helper({name, value}), do: {name, value}
end
