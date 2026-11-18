# frozen_string_literal: true

require_relative "lib/esuiss/relay/version"

Gem::Specification.new do |spec|
  spec.name = "esuiss-relay"
  spec.version = Esuiss::Relay::VERSION
  spec.summary = "Ruby server SDK for Relay"
  spec.description = "Relay server API client with DPoP-bound Access tokens, automatic idempotency keys, " \
                     "retries of retryable problems, lazy pagination, webhook verification and agent helpers."
  spec.authors = ["Suiss"]
  spec.license = "Apache-2.0"
  spec.homepage = "https://github.com/e-suiss/relay/tree/main/sdks/ruby"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "README.md"]
  spec.require_paths = ["lib"]
  spec.metadata = {
    "source_code_uri" => "https://github.com/e-suiss/relay/tree/main/sdks/ruby",
    "rubygems_mfa_required" => "true"
  }
end
