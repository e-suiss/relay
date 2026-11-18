# frozen_string_literal: true

require "date"
require "json"
require "minitest/autorun"
require "yaml"
require "esuiss/relay"

module TestSupport
  REPO = File.expand_path("../../..", __dir__)

  def self.repo_path(*parts)
    File.join(REPO, *parts)
  end

  def self.json_fixture(*parts)
    JSON.parse(File.read(repo_path(*parts)))
  end

  # Answers requests from a fixed list and records them.
  class StubTransport
    attr_reader :requests

    def initialize(*responses)
      @responses = responses
      @requests = []
    end

    def push(response)
      @responses << response
      self
    end

    def call(request)
      @requests << request
      response = @responses.shift
      raise "no stubbed response left for #{request.http_method} #{request.url}" if response.nil?
      raise response if response.is_a?(Exception)

      response
    end
  end

  # Hands out numbered DPoP headers and counts invalidations.
  class StubAuth
    attr_reader :invalidations, :calls

    def initialize
      @invalidations = 0
      @calls = 0
    end

    def authorize(_method, _url)
      @calls += 1
      { "Authorization" => "DPoP token", "DPoP" => "proof-#{@calls}" }
    end

    def invalidate
      @invalidations += 1
    end
  end

  # A Random stand-in returning a fixed fraction.
  class FixedRandom
    def initialize(value)
      @value = value
    end

    def rand
      @value
    end
  end

  def self.json(status, body, headers = {})
    Esuiss::Relay::Response.new(status: status, headers: { "content-type" => "application/json" }.merge(headers),
                                body: JSON.generate(body))
  end

  def self.problem(status, code, retryable:, **extra)
    json(status, { "type" => "https://relay.test/v1/errors/#{code}", "title" => code, "status" => status,
                   "code" => code, "retryable" => retryable }.merge(extra.transform_keys(&:to_s)),
         { "content-type" => "application/problem+json" })
  end

  def self.client(transport, **options)
    sleeps = []
    client = Esuiss::Relay::Client.new(
      base_url: "https://relay.test",
      auth: options.delete(:auth) || StubAuth.new,
      transport: transport,
      random: options.delete(:random) || FixedRandom.new(0.5),
      sleeper: ->(seconds) { sleeps << seconds },
      clock: -> { Time.at(1_800_000_000) },
      **options
    )
    [client, sleeps]
  end
end
