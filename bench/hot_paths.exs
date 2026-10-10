RelayDev.BenchCases.all()
|> Map.new()
|> Benchee.run(
  time: 5,
  memory_time: 1,
  warmup: 2,
  formatters: [{Benchee.Formatters.Console, extended_statistics: true}]
)
