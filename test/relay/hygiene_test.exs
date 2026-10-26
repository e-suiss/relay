defmodule Relay.HygieneTest do
  use ExUnit.Case, async: true

  alias Relay.Hygiene
  alias Relay.Redacted

  @secret "s3cr3t-value"

  defp lib_sources(globs) do
    globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.map(&{&1, File.read!(&1)})
  end

  describe "T-46 process-side secret hygiene" do
    test "T-46: format_status keeps secrets out of the state, the message, the log and the crash reason" do
      stacktrace = [
        {Relay.Keys.Port, :handle_call, [{:request, @secret}, self(), %{}], [line: 1]}
      ]

      status =
        Hygiene.format_status(
          %{
            state: %{key: @secret, count: 1},
            message: {:request, @secret},
            log: [{:in, @secret}],
            reason:
              {%FunctionClauseError{module: M, function: :f, arity: 1, args: [@secret]},
               stacktrace}
          },
          fn state -> %{state | key: :redacted} end
        )

      refute inspect(status, limit: :infinity, printable_limit: :infinity) =~ @secret
      assert status.state.count == 1
      assert {_, [{Relay.Keys.Port, :handle_call, 3, [line: 1]}]} = status.reason
    end

    test "T-46: process crash reports lose stack trace and exception arguments before any handler" do
      assert {Relay.Hygiene, _} =
               :logger.get_primary_config().filters |> List.keyfind(Relay.Hygiene, 0)

      report = %{
        label: {:gen_server, :terminate},
        reason:
          {:function_clause, [{M, :handle_call, [{:leak, @secret}, self(), %{}], [line: 1]}]},
        state: :kept
      }

      assert %{msg: {:report, pruned}} =
               Hygiene.crash_report_filter(
                 %{msg: {:report, report}, meta: %{}, level: :error},
                 []
               )

      refute inspect(pruned, limit: :infinity, printable_limit: :infinity) =~ @secret
      assert pruned.state == :kept

      statem = %{reason: {:error, %MatchError{term: @secret}, [{M, :f, [@secret], []}]}}

      assert %{msg: {:report, pruned}} =
               Hygiene.crash_report_filter(%{msg: {:report, statem}}, [])

      refute inspect(pruned, limit: :infinity, printable_limit: :infinity) =~ @secret

      other = %{msg: {:string, "plain"}}
      assert Hygiene.crash_report_filter(other, []) == other
    end

    test "T-46: stack trace arguments are pruned to their count" do
      assert Hygiene.prune_stacktrace([{M, :f, [@secret, 2], [file: ~c"m.ex"]}, {M, :g, 1, []}]) ==
               [{M, :f, 2, [file: ~c"m.ex"]}, {M, :g, 1, []}]

      assert Hygiene.prune_reason({:badmatch, @secret}) == {:badmatch, :redacted}

      assert Relay.LogRedactor.scrub(%{st: [{M, :f, [@secret], [line: 3]}]}) == %{
               st: [{M, :f, 1, [line: 3]}]
             }
    end

    test "T-46: a struct whose inspection shows a declared secret field does not compile" do
      leaky = """
      defmodule Relay.HygieneTest.Leaky do
        defstruct [:token, :name]
        use Relay.Hygiene, secret_fields: [:token]
      end
      """

      assert_raise CompileError, ~r/needs @derive/, fn -> Code.compile_string(leaky) end

      assert {:error, message} = Hygiene.check_inspect(Relay.Secrets.Ref, [:fingerprint])
      assert message =~ "shows a secret field"
    end

    test "T-46: a struct with an allowlist of shown fields does not compile when another field shows" do
      leaky = """
      defmodule Relay.HygieneTest.LeakyRef do
        @derive {Inspect, only: [:id, :ref]}
        defstruct [:id, :ref]
        use Relay.Hygiene, shown_fields: [:id]
      end
      """

      assert_raise CompileError, ~r/Relay.HygieneTest.LeakyRef/, fn ->
        Code.compile_string(leaky)
      end

      assert Hygiene.secret_fields(Relay.Secrets.Ref) == [:created_at, :retired_at]
      assert Hygiene.check_inspect(Relay.Secrets.Ref, [:created_at, :retired_at]) == :ok
    end

    test "T-46: structs that hold secrets restrict their inspection with only:" do
      cache = %Relay.Tenancy.KeyCache{entries: %{k: {Redacted.wrap(@secret), 0}}}
      refute inspect(cache, limit: :infinity) =~ "entries"
      assert Hygiene.check_inspect(Relay.Tenancy.KeyCache, [:entries]) == :ok

      ref = %Relay.Secrets.Ref{
        id: <<1::128>>,
        kind: :webhook_signing,
        ref_version: 1,
        fingerprint: <<2::256>>,
        state: :active
      }

      assert inspect(ref) =~ "fingerprint"
    end

    test "T-46: the key store server's status shows no pending request or program argument" do
      status =
        Relay.Keys.Port.format_status(%{
          state: %{pending: %{1 => {self(), make_ref(), :unwrap}}, args: ["--pin-file", @secret]},
          message: {:request, {:hmac, "bidx", @secret}}
        })

      assert status.state.pending == 1
      refute inspect(status) =~ @secret
    end

    test "T-46: no ETS table Relay creates is public" do
      for {path, source} <- lib_sources(["lib/**/*.ex"]),
          [call] <- Regex.scan(~r/:ets\.new\([^)]*\)/s, source) do
        refute call =~ ":public", "#{path}: #{call}"
      end
    end

    test "TN-66: key material and resolved secrets are never put in ETS or persistent_term" do
      for {path, source} <-
            lib_sources([
              "lib/relay/keys.ex",
              "lib/relay/keys/**/*.ex",
              "lib/relay/tenancy/{key_cache,keyring,field_cipher,blind_index}.ex",
              "lib/relay/secrets.ex",
              "lib/relay/secrets/**/*.ex"
            ]) do
        refute source =~ ~r/:ets\.|:persistent_term\.|Registry\./, path
      end
    end
  end
end
