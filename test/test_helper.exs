Mox.defmock(Relay.ClockMock, for: Relay.Clock)
Mox.defmock(Relay.RandomMock, for: Relay.Random)
Mox.defmock(Relay.Tenancy.KeyProviderMock, for: Relay.Tenancy.KeyProvider)
Mox.defmock(Relay.ValkeyMock, for: Relay.Platform.Valkey)
Mox.defmock(Relay.KeysMock, for: Relay.Keys)

ExUnit.start(exclude: [:integration, :nightly, :quarantine])
