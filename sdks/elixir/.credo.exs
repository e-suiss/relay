%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "lib_dev/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      checks: %{
        extra: [
          {Credo.Check.Readability.ModuleDoc, [files: %{included: ["lib/", "lib_dev/"]}]},
          {Credo.Check.Warning.UnsafeToAtom, []}
        ]
      }
    }
  ]
}
