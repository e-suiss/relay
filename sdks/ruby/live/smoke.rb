# frozen_string_literal: true

require "esuiss/relay"

# X-48
auth = Esuiss::Relay::ClientCredentials.new(
  issuer: ENV.fetch("RELAY_SDK_LIVE_ISSUER"),
  client_id: ENV.fetch("RELAY_SDK_LIVE_CLIENT_ID"),
  client_secret: ENV.fetch("RELAY_SDK_LIVE_CLIENT_SECRET")
)
client = Esuiss::Relay::Client.new(base_url: ENV.fetch("RELAY_SDK_LIVE_BASE_URL"), auth: auth)

accepted = client.create_event({ "workflow" => "welcome", "to" => [{ "id" => "sdk-ruby-live" }] })
abort "the event was not accepted" unless accepted.is_a?(Hash)

client.list_notifications(limit: 1).first
puts "live smoke passed"
