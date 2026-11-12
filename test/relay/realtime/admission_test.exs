defmodule Relay.Realtime.AdmissionTest do
  use ExUnit.Case, async: true

  alias Relay.Realtime.Admission

  describe "IN-52 IN-34 node accept rate" do
    test "IN-52: the contract sets the accept rate, burst, Retry-After and connection limit" do
      assert Relay.Limits.fetch!(["realtime", "accept_per_second"]) == 200
      assert Relay.Limits.fetch!(["realtime", "accept_burst"]) == 400
      assert Relay.Limits.fetch!(["realtime", "retry_after_seconds"]) == %{"min" => 1, "max" => 5}
      assert Relay.Limits.fetch!(["realtime", "max_connections_per_subscriber"]) == 10

      for _n <- 1..200, do: assert(Admission.retry_after() in 1..5)
    end

    test "IN-52: the bucket refills at the rate up to the burst" do
      bucket = %{tokens: 2.0, at_ms: 0, rate: 200, burst: 2}

      assert {:ok, bucket} = Admission.step(bucket, 0)
      assert {:ok, bucket} = Admission.step(bucket, 0)
      assert {:empty, bucket} = Admission.step(bucket, 4)
      assert {:ok, bucket} = Admission.step(bucket, 5)
      assert {:empty, _bucket} = Admission.step(bucket, 5)
      assert {:ok, %{tokens: 1.0}} = Admission.step(bucket, 60_000)
    end

    test "IN-34: an empty bucket refuses with a jittered Retry-After" do
      name = :"admission_#{System.unique_integer([:positive])}"
      start_supervised!({Admission, name: name, rate: 1, burst: 2})

      assert :ok = Admission.take(name)
      assert :ok = Admission.take(name)
      assert {:error, retry_after} = Admission.take(name)
      assert retry_after in 1..5
    end
  end
end
