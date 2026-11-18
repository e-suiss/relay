# frozen_string_literal: true

require "test_helper"

class GeneratedTest < Minitest::Test
  SPEC = YAML.safe_load_file(TestSupport.repo_path("contracts", "openapi", "server.yaml"),
                             permitted_classes: [Date, Time], aliases: true)

  def snake(operation_id)
    operation_id.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase
  end

  def test_x48_api_version_is_pinned_to_the_contract
    assert_equal SPEC.dig("info", "version").to_s, Esuiss::Relay::API_VERSION
  end

  def test_x48_tenant_operations_are_generated_and_inbound_ones_are_not
    methods = Esuiss::Relay::Generated::Operations.instance_methods

    %w[createEvent listNotifications getNotification createWaitpoint getWaitpoint heartbeatWaitpoint
       listMailboxRecords leaseMailboxRecords ackMailboxRecords getErrorCode getRelayConfiguration].each do |id|
      assert_includes methods, snake(id).to_sym, id
    end
    %w[receiveAccessEvent receiveProviderWebhook verifyWhatsappWebhook completeMessagingInstallation].each do |id|
      refute_includes methods, snake(id).to_sym, id
    end
  end
end
