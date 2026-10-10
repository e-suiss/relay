Mox.defmock(Relay.ClockMock, for: Relay.Clock)
Mox.defmock(Relay.RandomMock, for: Relay.Random)

ExUnit.start(exclude: [:integration, :quarantine])
