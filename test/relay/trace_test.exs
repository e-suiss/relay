defmodule Relay.TraceTest do
  use ExUnit.Case, async: false

  alias Relay.Trace
  alias Relay.Trace.Exporter
  alias Relay.Trace.Jobs

  @trace "4bf92f3577b34da6a3ce929d0e0e4736"
  @span "00f067aa0ba902b7"
  @parent "00-" <> @trace <> "-" <> @span <> "-01"

  setup do
    previous = Logger.metadata()
    on_exit(fn -> Logger.reset_metadata(previous) end)
    Logger.reset_metadata([])
    :ok
  end

  defp with_exporter(fun) do
    previous = Application.get_env(:relay, Relay.Trace)
    config = [endpoint: "http://collector.test:4318", http: [plug: {Req.Test, Exporter}]]
    Application.put_env(:relay, Relay.Trace, config)
    test = self()

    Req.Test.stub(Exporter, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:otlp, conn.request_path, Jason.decode!(body)})
      Req.Test.json(conn, %{})
    end)

    pid = start_supervised!(Exporter)
    Req.Test.allow(Exporter, test, pid)

    try do
      fun.()
    after
      Application.put_env(:relay, Relay.Trace, previous || [])
    end
  end

  describe "OP-34 trace context" do
    test "OP-34: a traceparent is parsed, continued by a child and refused when malformed" do
      assert {:ok, %{trace_id: @trace, span_id: @span}} = Trace.parse(@parent)

      assert Trace.parse("00-" <> String.duplicate("0", 32) <> "-" <> @span <> "-01") == :error
      assert Trace.parse("01-" <> @trace <> "-" <> @span <> "-01") == :error
      assert Trace.parse("not a context") == :error
      assert Trace.parse(nil) == :error

      child = Trace.child(@parent)
      assert {:ok, %{trace_id: @trace, span_id: span}} = Trace.parse(child)
      refute span == @span

      assert {:ok, %{trace_id: trace}} = Trace.parse(Trace.child("garbage"))
      refute trace == @trace
      assert Trace.valid?(Trace.new())
    end

    test "T-63: the current context and its identifiers join the logger metadata" do
      assert Trace.current() == nil
      :ok = Trace.put(@parent)

      assert Trace.current() == @parent
      assert Logger.metadata()[:trace_id] == @trace
      assert Logger.metadata()[:span_id] == @span
      assert Trace.headers() == [{"traceparent", @parent}]

      inside = Trace.span("work", fn -> Trace.current() end)
      assert {:ok, %{trace_id: @trace}} = Trace.parse(inside)
      refute inside == @parent
      assert Trace.current() == @parent
    end

    test "E-72: the HTTP plug continues an incoming traceparent or starts a trace" do
      conn =
        Plug.Test.conn(:get, "/livez")
        |> Plug.Conn.put_req_header("traceparent", @parent)
        |> RelayWeb.Plugs.Trace.call([])

      assert {:ok, %{trace_id: @trace}} = Trace.parse(Trace.current())
      assert conn.before_send != []

      Plug.Test.conn(:get, "/livez")
      |> Plug.Conn.put_req_header("traceparent", "00-bad")
      |> RelayWeb.Plugs.Trace.call([])

      assert {:ok, %{trace_id: trace}} = Trace.parse(Trace.current())
      refute trace == @trace
    end
  end

  describe "OP-34 jobs" do
    test "OP-34: a job carries the trace context and correlation id of the code that built it" do
      Logger.metadata(correlation_id: "cor_trace")
      :ok = Trace.put(@parent)

      args = %{"kill_switch_id" => "x", "platform" => false}
      changeset = Relay.Tenancy.KillSwitch.Sweep.new(args)

      assert %{"traceparent" => @parent, "correlation_id" => "cor_trace"} =
               Ecto.Changeset.get_field(changeset, :meta)

      kept = Jobs.opts(meta: %{"own" => 1})
      assert kept[:meta]["own"] == 1
      assert kept[:meta]["traceparent"] == @parent

      Logger.reset_metadata([])
      assert Jobs.opts(queue: :maintenance) == [queue: :maintenance]
    end

    test "OP-34: a job continues its context in a child span and takes its correlation id" do
      job = %Oban.Job{
        id: 1,
        queue: "maintenance",
        worker: "Relay.Tenancy.KillSwitch.Sweep",
        attempt: 1,
        meta: %{"traceparent" => @parent, "correlation_id" => "cor_job"}
      }

      :ok = Jobs.handle_event([:oban, :job, :start], %{}, %{job: job}, nil)

      assert Logger.metadata()[:correlation_id] == "cor_job"
      assert {:ok, %{trace_id: @trace}} = Trace.parse(Trace.current())
      refute Trace.current() == @parent

      assert :ok = Jobs.handle_event([:oban, :job, :stop], %{}, %{job: job, state: :success}, nil)
    end
  end

  describe "OP-32 exporter" do
    test "OP-32: spans reach the collector as OTLP JSON with only the fixed attributes" do
      with_exporter(fn ->
        :ok = Trace.put(@parent)

        attributes = %{"relay.channel" => "sms", "recipient" => "+905551112233"}
        opts = [attributes: attributes, links: [Trace.new(), "bad"]]
        :ok = Trace.span("provider event", opts, fn -> :ok end)

        :ok = Exporter.flush()

        assert_receive {:otlp, "/v1/traces", %{"resourceSpans" => [resource]}}
        assert [%{"spans" => [span]}] = resource["scopeSpans"]
        assert span["traceId"] == @trace
        assert span["parentSpanId"] == @span
        assert span["name"] == "provider event"
        channel = %{"key" => "relay.channel", "value" => %{"stringValue" => "sms"}}
        assert span["attributes"] == [channel]
        assert [%{"traceId" => _, "spanId" => _}] = span["links"]
        refute inspect(span) =~ "905551112233"
      end)
    end

    test "OP-32: without an endpoint no exporter runs and spans are dropped" do
      assert Exporter.children() == []
      assert :ok = Trace.span("work", fn -> :ok end)
      assert "recipient" not in Trace.attribute_keys()
    end
  end
end
