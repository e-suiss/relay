# frozen_string_literal: true

require_relative "relay/version"
require_relative "relay/generated/api"
require_relative "relay/generated/operations"
require_relative "relay/codec"
require_relative "relay/errors"
require_relative "relay/transport"
require_relative "relay/dpop"
require_relative "relay/client_credentials"
require_relative "relay/retry_policy"
require_relative "relay/page"
require_relative "relay/webhook"
require_relative "relay/agents"
require_relative "relay/client"

module Esuiss
  # X-28
  # Ruby server SDK of Relay, pinned to API version Generated::API_VERSION.
  module Relay
    API_VERSION = Generated::API_VERSION
  end
end
