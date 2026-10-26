defmodule Relay.Platform.FanoutTest do
  use Relay.SqlCase, async: true

  import RelayTest.WaitpointFixture

  alias Relay.Platform.Fanout

  setup do
    %{s: setup!()}
  end

  defp at(ms), do: Relay.Id.build(ms, <<0::80>>)

  defp create(bounds, opts \\ []) do
    row("SELECT * FROM relay_fn.fanout_create($1, $2, $3, $4, $5, $6, $7, $8)", [
      Keyword.get_lazy(opts, :id, &id/0),
      "campaign",
      Keyword.get_lazy(opts, :source_id, &id/0),
      "l1",
      "bulk",
      Keyword.get(opts, :slice_size, 5_000),
      Keyword.get(opts, :sub_batch_size, 200),
      bounds
    ])
  end

  defp three_slices do
    ["created", fanout, 3] = create([nil, at(1_000), at(2_000), nil])
    fanout
  end

  defp begin(fanout, slice_no),
    do: row("SELECT * FROM relay_fn.fanout_slice_begin($1, $2)", [fanout, slice_no])

  defp checkpoint(fanout, slice_no, after_id, processed \\ 0, failed \\ 0),
    do:
      one("SELECT relay_fn.fanout_slice_checkpoint($1, $2, $3, $4, $5)", [
        fanout,
        slice_no,
        after_id,
        processed,
        failed
      ])

  defp finish(fanout, slice_no, state),
    do: row("SELECT * FROM relay_fn.fanout_slice_finish($1, $2, $3)", [fanout, slice_no, state])

  defp fanout(fanout, column),
    do: one("SELECT #{column} FROM relay.fanouts WHERE id = $1", [fanout])

  defp events(fanout),
    do:
      "SELECT event_type FROM relay.outbox_events WHERE stream_key = $1 ORDER BY seq"
      |> rows(["fanout:" <> Ecto.UUID.load!(fanout)])
      |> List.flatten()

  describe "T-23 T-91 slicing" do
    test "T-91: the model follows the audience size" do
      assert Fanout.mode(0) == :normal
      assert Fanout.mode(1_000) == :normal
      assert Fanout.mode(1_001) == :bulk
      assert Fanout.mode(100_000) == :bulk
      assert Fanout.mode(100_001) == :campaign
      assert Fanout.default_sizes() == %{slice_size: 5_000, sub_batch_size: 200}
    end

    test "T-23: a fan-out holds one slice per keyset range and nothing per recipient" do
      fanout = three_slices()

      assert rows(
               "SELECT slice_no, range_from, range_to, state FROM relay.fanout_slices WHERE fanout_id = $1 ORDER BY slice_no",
               [fanout]
             ) == [
               [0, nil, at(1_000), "pending"],
               [1, at(1_000), at(2_000), "pending"],
               [2, at(2_000), nil, "pending"]
             ]

      assert fanout(fanout, "state") == "pending"
    end

    test "T-23: the same source creates one fan-out" do
      source = id()
      ["created", fanout, 1] = create([nil, nil], source_id: source)
      assert ["exists", ^fanout, 1] = create([nil, at(5), nil], source_id: source)
      assert ["exists", ^fanout, 1] = create([nil, nil], id: fanout)
    end

    test "T-23: bounds must rise and only the ends may be open" do
      assert ["invalid_bounds", nil, nil] = create([nil])
      assert ["invalid_bounds", nil, nil] = create([nil, at(2), at(1), nil])
      assert ["invalid_bounds", nil, nil] = create([nil, at(2), at(2), nil])
      assert ["invalid_bounds", nil, nil] = create([nil, nil, at(1)])
    end

    test "T-23: slice and sub-batch sizes are bounded" do
      assert sql_error(
               "SELECT * FROM relay_fn.fanout_create($1, 'campaign', $2, 'l1', 'bulk', 100, 101, ARRAY[NULL, NULL]::uuid[])",
               [id(), id()]
             ).postgres.constraint == "fanouts_size_check"
    end
  end

  describe "T-23 progress and closing" do
    test "T-23: slices move their checkpoint forward inside their range and close the fan-out" do
      fanout = three_slices()

      assert ["begun", nil, to] = begin(fanout, 1)
      assert to == at(2_000)
      assert fanout(fanout, "state") == "running"
      assert checkpoint(fanout, 1, at(1_200), 150, 2) == "continue"
      assert ["resumed", checkpoint, ^to] = begin(fanout, 1)
      assert checkpoint == at(1_200)

      for bad <- [at(1_100), at(1_200), at(2_000), at(900)] do
        assert error_message("SELECT relay_fn.fanout_slice_checkpoint($1, 1, $2, 1, 0)", [
                 fanout,
                 bad
               ]) =~ "invalid_argument"
      end

      assert checkpoint(fanout, 0, at(10)) == "not_running"
      assert ["finished", "running"] = finish(fanout, 1, "completed")
      assert ["already_terminal", "running"] = finish(fanout, 1, "completed")
      assert ["already_terminal", _, _] = begin(fanout, 1)

      for n <- [0, 2] do
        ["begun", _, _] = begin(fanout, n)
        assert checkpoint(fanout, n, nil, 10, 0) == "continue"
      end

      assert ["finished", "running"] = finish(fanout, 0, "completed")
      assert ["finished", "completed"] = finish(fanout, 2, "completed")
      assert fanout(fanout, "processed_count") == 150
      assert fanout(fanout, "failed_count") == 2
      assert fanout(fanout, "slices_completed") == 3
      assert events(fanout) == ["fanout.completed"]
    end

    test "T-23: a failed slice closes the fan-out as partial" do
      ["created", fanout, 2] = create([nil, at(1_000), nil])
      for n <- [0, 1], do: ["begun", _, _] = begin(fanout, n)
      assert ["finished", "running"] = finish(fanout, 0, "failed")
      assert ["finished", "partial"] = finish(fanout, 1, "completed")
      assert events(fanout) == ["fanout.partial"]
    end

    test "T-34: a paused fan-out holds its slices until it resumes" do
      fanout = three_slices()

      assert one("SELECT relay_fn.fanout_pause($1, 'kill_switch.tenant')", [fanout]) == "paused"

      assert one("SELECT relay_fn.fanout_pause($1, 'kill_switch.tenant')", [fanout]) ==
               "already_paused"

      assert fanout(fanout, "pause_rule_id") == "kill_switch.tenant"
      assert ["paused", nil, _] = begin(fanout, 0)
      assert one("SELECT relay_fn.fanout_resume($1)", [fanout]) == "resumed"
      assert fanout(fanout, "state") == "pending"
      assert one("SELECT relay_fn.fanout_resume($1)", [fanout]) == "not_paused"

      ["begun", _, _] = begin(fanout, 0)
      assert one("SELECT relay_fn.fanout_pause($1, 'shed.l2')", [fanout]) == "paused"
      assert checkpoint(fanout, 0, at(10), 5, 0) == "paused"
      assert one("SELECT relay_fn.fanout_resume($1)", [fanout]) == "resumed"
      assert fanout(fanout, "state") == "running"
    end
  end

  describe "T-23 (4) cancellation" do
    test "T-23: cancelling closes pending slices at once and a running slice stops at its next check" do
      fanout = three_slices()
      ["begun", _, _] = begin(fanout, 0)

      assert ["cancelled", 2] =
               row(
                 "SELECT * FROM relay_fn.fanout_cancel($1, 'operator.cancel', $2, $3, $4, $5, $6)",
                 [
                   fanout,
                   digest() | actor()
                 ]
               )

      assert fanout(fanout, "state") == "cancelled"
      assert events(fanout) == []
      assert checkpoint(fanout, 0, at(10), 3, 0) == "cancelled"
      assert ["cancelled", _, _] = begin(fanout, 0)
      assert ["finished", "cancelled"] = finish(fanout, 0, "cancelled")
      assert fanout(fanout, "slices_cancelled") == 3
      assert events(fanout) == ["fanout.cancelled"]

      assert ["already_closed", 0] =
               row(
                 "SELECT * FROM relay_fn.fanout_cancel($1, 'operator.cancel', $2, $3, $4, $5, $6)",
                 [
                   fanout,
                   digest() | actor()
                 ]
               )
    end
  end
end
