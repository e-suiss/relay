require "esuiss/relay"
require "set"

module DocsExamples
  def self.quickstart
    # #region quickstart
    auth = Esuiss::Relay::ClientCredentials.new(
      issuer: "https://access.example.com",
      client_id: ENV.fetch("ACCESS_CLIENT_ID"),
      client_secret: ENV.fetch("ACCESS_CLIENT_SECRET")
    )
    relay = Esuiss::Relay::Client.new(base_url: "https://relay.example.com", auth: auth)

    accepted = relay.create_event(
      {
        "workflow" => "welcome",
        "to" => [{ "id" => "user-4821", "email" => "ayse@example.com" }],
        "data" => { "first_name" => "Ayşe" }
      }
    )
    puts accepted["id"]
    # #endregion quickstart

    # #region decisions
    relay.list_subscriber_decisions("user-4821", limit: 10).each do |decision|
      decision["deliveries"].each do |delivery|
        puts "#{decision['notification_id']} #{delivery['channel']} #{delivery['status']}"
      end
    end
    # #endregion decisions

    # #region errors
    begin
      relay.create_event({ "workflow" => "welcome", "to" => [] })
    rescue Esuiss::Relay::ValidationError => e
      puts "#{e.status} #{e.code} #{e.request_id}"
    end
    # #endregion errors
  end

  PROCESSED = Set.new

  # #region verify
  def self.handle_relay_webhook(raw_body, headers)
    webhook = Esuiss::Relay::Webhook.new([ENV.fetch("RELAY_WEBHOOK_PUBLIC_KEY")])
    event = webhook.construct_event(raw_body, headers)
    puts "received #{event['type']}" if PROCESSED.add?(event["id"])
    204
  rescue Esuiss::Relay::WebhookVerificationError
    400
  end
  # #endregion verify
end
