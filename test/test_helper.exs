Mox.defmock(Relay.ClockMock, for: Relay.Clock)
Mox.defmock(Relay.RandomMock, for: Relay.Random)
Mox.defmock(Relay.Tenancy.KeyProviderMock, for: Relay.Tenancy.KeyProvider)
Mox.defmock(Relay.ValkeyMock, for: Relay.Platform.Valkey)
Mox.defmock(Relay.KeysMock, for: Relay.Keys)

mjml_port = Path.expand("../native/mjml_port/target/release/mjml_port", __DIR__)

if File.exists?(mjml_port <> ".sha256") do
  sha256 = (mjml_port <> ".sha256") |> File.read!() |> String.split() |> hd()
  Application.put_env(:relay, Relay.Templates.Mjml, executable: mjml_port, sha256: sha256)
end

ExUnit.start(exclude: [:integration, :nightly, :quarantine])
