%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "lib_dev/", "test/", "config/", "bench/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      plugins: [],
      requires: [],
      checks: %{
        extra: [
          {Credo.Check.Warning.Dbg, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.UnsafeToAtom, []},
          {Credo.Check.Readability.Specs, false},
          {Credo.Check.Design.TagTODO, false},
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, false},
          {Credo.Check.Design.AliasUsage,
           [if_nested_deeper_than: 2, if_called_more_often_than: 1]},
          {Credo.Check.Readability.ModuleDoc, [files: %{included: ["lib/", "lib_dev/"]}]},
          {RelayDev.Credo.NoDirectClock,
           [
             files: %{
               included: ["lib/"],
               excluded: ["lib/relay/clock/system.ex", "lib/relay/random/strong.ex"]
             }
           ]},
          {RelayDev.Credo.UnsafeConversion, [files: %{included: ["lib/"]}]},
          {RelayDev.Credo.BareProcess,
           [files: %{included: ["lib/"], excluded: ["lib/relay/process.ex"]}]},
          {RelayDev.Credo.RepoOutsideStore,
           [
             files: %{
               included: ["lib/"],
               excluded: ["lib/relay/repo.ex", "lib/relay/bulk_repo.ex", "lib/relay/release.ex"]
             }
           ]},
          {RelayDev.Credo.LaneOutsideLane,
           [files: %{included: ["lib/"], excluded: ["lib/relay/platform/lane.ex"]}]},
          {RelayDev.Credo.TodoWithIssue, []},
          {RelayDev.Credo.PublicApiDocs, [files: %{included: ["lib/"]}]},
          {RelayDev.Credo.MailboxRules, [files: %{included: ["lib/"]}]},
          {RelayDev.Credo.OffHeapMailbox,
           [
             files: %{
               included: [
                 "lib/relay/platform/queue/notifier.ex",
                 "lib/relay/platform/valkey/redix/forwarder.ex",
                 "lib/relay/platform/signal/hub.ex"
               ]
             }
           ]},
          {RelayDev.Credo.BinaryCopy,
           [files: %{included: ["lib/"], excluded: ["lib/relay/binary.ex"]}]},
          {RelayDev.Credo.RestartBudget, [files: %{included: ["lib/"]}]},
          {RelayDev.Credo.EtsTables, [files: %{included: ["lib/"]}]},
          {RelayDev.Credo.PersistentTerm,
           [
             files: %{
               included: ["lib/"],
               excluded: [
                 "lib/relay/datasets.ex",
                 "lib/relay/platform/backend.ex",
                 "lib/relay/platform/load_shed.ex"
               ]
             }
           ]},
          {RelayDev.Credo.TenantProcesses,
           [files: %{included: ["lib/"], excluded: ["lib/relay/tenant_worker.ex"]}]},
          {RelayDev.Credo.LimitClock,
           [
             files: %{
               included: [
                 "lib/relay/platform/rate_limit.ex",
                 "lib/relay/platform/rate_limit/",
                 "lib/relay/platform/concurrency.ex",
                 "lib/relay/platform/concurrency/"
               ]
             }
           ]}
        ]
      }
    }
  ]
}
