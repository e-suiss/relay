Mox.defmock(Relay.ClockMock, for: Relay.Clock)
Mox.defmock(Relay.RandomMock, for: Relay.Random)
Mox.defmock(Relay.Tenancy.KeyProviderMock, for: Relay.Tenancy.KeyProvider)
Mox.defmock(Relay.ValkeyMock, for: Relay.Platform.Valkey)

ExUnit.start(exclude: [:integration, :quarantine])
