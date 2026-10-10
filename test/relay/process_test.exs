defmodule Relay.ProcessTest do
  use ExUnit.Case, async: true

  test "T-47: background work carries logger metadata and the correlation id" do
    Logger.metadata(correlation_id: "cor_test", request_id: "req_1")
    task = Relay.Process.async(fn -> Logger.metadata() end)
    metadata = Task.await(task)

    assert metadata[:correlation_id] == "cor_test"
    assert metadata[:request_id] == "req_1"
  end

  test "T-47: background work without a correlation id is refused" do
    Logger.reset_metadata()

    assert_raise ArgumentError, ~r/correlation_id/, fn ->
      Relay.Process.start_task(fn -> :ok end)
    end
  end
end
