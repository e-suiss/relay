# frozen_string_literal: true

require "test_helper"

class ErrorsTest < Minitest::Test
  CATALOG = YAML.safe_load_file(TestSupport.repo_path("contracts", "errors.yaml"), permitted_classes: [Date, Time])
  FAMILY_CLASSES = {
    "auth" => Esuiss::Relay::AuthenticationError,
    "idempotency" => Esuiss::Relay::IdempotencyError,
    "quota" => Esuiss::Relay::RateLimitError
  }.freeze

  def test_x29_generated_table_matches_the_error_catalog
    CATALOG.fetch("codes").each do |entry|
      row = Esuiss::Relay::Generated::ERROR_CODES.fetch(entry.fetch("code"))

      assert_equal({ family: entry.fetch("family"), status: entry.fetch("status"),
                     retryable: entry.fetch("retryable") == true }, row)
    end
    assert_equal CATALOG.fetch("codes").size, Esuiss::Relay::Generated::ERROR_CODES.size
  end

  def test_x29_every_catalog_code_maps_to_a_typed_error_with_its_retryable_flag
    CATALOG.fetch("codes").each do |entry|
      status = entry.fetch("status")
      response = TestSupport.problem(status, entry.fetch("code"), retryable: entry.fetch("retryable") == true)
      error = Esuiss::Relay::Errors.from_response(response)

      assert_instance_of expected_class(entry.fetch("family"), status), error, entry.fetch("code")
      assert_equal entry.fetch("retryable") == true, error.retryable?
      assert_kind_of Esuiss::Relay::APIError, error
    end
  end

  def test_x29_unknown_codes_fall_back_to_the_status
    {
      401 => Esuiss::Relay::AuthenticationError, 404 => Esuiss::Relay::NotFoundError,
      409 => Esuiss::Relay::ConflictError, 429 => Esuiss::Relay::RateLimitError,
      400 => Esuiss::Relay::ValidationError, 502 => Esuiss::Relay::ServerError
    }.each do |status, klass|
      error = Esuiss::Relay::Errors.from_response(Esuiss::Relay::Response.new(status: status, body: "not json"))

      assert_instance_of klass, error
      refute_predicate error, :retryable?
    end
  end

  def test_x29_problem_members_are_exposed
    extra = { retry_after: 4, request_id: "req_1", detail: "slow down" }
    response = TestSupport.problem(429, "rate_limited", retryable: true, **extra)
    error = Esuiss::Relay::Errors.from_response(response)

    assert_equal 4, error.retry_after
    assert_equal "req_1", error.request_id
    assert_equal 429, error.status
    assert_includes error.message, "slow down"
  end

  private

  def expected_class(family, status)
    FAMILY_CLASSES.fetch(family) do
      if status >= 500 then Esuiss::Relay::ServerError
      elsif status == 429 then Esuiss::Relay::RateLimitError
      elsif status == 404 then Esuiss::Relay::NotFoundError
      elsif [409, 412, 428].include?(status) then Esuiss::Relay::ConflictError
      else Esuiss::Relay::ValidationError
      end
    end
  end
end
