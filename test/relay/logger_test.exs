defmodule Relay.LoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  setup do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  test "T-63: logs are structured JSON carrying the correlation fields" do
    formatter = Application.fetch_env!(:logger, :default_handler)[:formatter]

    log =
      capture_log([formatter: formatter, level: :info], fn ->
        Logger.metadata(correlation_id: "cor_1", request_id: "req_1", tenant_id: "tnt_opaque")

        Logger.info("delivery accepted",
          delivery_id: "dlv_1",
          provider_credential: Relay.Redacted.wrap("secret-token"),
          recipients: [Relay.Redacted.wrap("secret-token")],
          password: "secret-token"
        )
      end)

    [line | _] = String.split(log, "\n", trim: true)
    decoded = Jason.decode!(line)

    assert decoded["message"] == "delivery accepted"
    assert decoded["metadata"]["correlation_id"] == "cor_1"
    assert decoded["metadata"]["request_id"] == "req_1"
    assert decoded["metadata"]["delivery_id"] == "dlv_1"
    refute log =~ "secret-token"
  end
end
