defmodule Relay.Templates.EvalBoundaryTest do
  use Credo.Test.Case

  alias RelayDev.Credo.UnsafeConversion

  @root Path.expand("../../../lib", __DIR__)

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  test "TP-2 TP-3: no template module reaches EEx, evaluation, atom creation or term decoding" do
    templates = Path.wildcard(Path.join(@root, "relay/templates/**/*.ex"))
    files = [Path.join(@root, "relay/templates.ex") | templates]
    assert length(files) > 1

    for file <- files do
      issues = file |> File.read!() |> to_source_file(file) |> run_check(UnsafeConversion)
      assert issues == [], "#{file} crosses the eval boundary"
    end
  end
end
