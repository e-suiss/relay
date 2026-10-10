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
           [files: %{included: ["lib/"], excluded: ["lib/relay/repo.ex", "lib/relay/release.ex"]}]},
          {RelayDev.Credo.TodoWithIssue, []},
          {RelayDev.Credo.PublicApiDocs, [files: %{included: ["lib/"]}]}
        ]
      }
    }
  ]
}
