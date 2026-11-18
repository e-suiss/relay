# frozen_string_literal: true

require "test_helper"

class PageTest < Minitest::Test
  include TestSupport

  def list(ids, cursor)
    TestSupport.json(200, { "object" => "list", "data" => ids.map { |id| { "id" => id } },
                            "has_more" => !cursor.nil?, "next_cursor" => cursor })
  end

  def test_api56_pages_are_fetched_lazily_with_the_same_filters
    transport = StubTransport.new(list(%w[ntf_1 ntf_2], "c1"), list(%w[ntf_3], "c2"), list(%w[ntf_4], nil))
    client, = TestSupport.client(transport)
    page = client.list_notifications(limit: 2, workflow: "welcome")

    assert_equal 1, transport.requests.size
    assert_predicate page, :more?
    assert_equal %w[ntf_1 ntf_2 ntf_3], page.lazy.map { |item| item["id"] }.first(3)
    assert_equal 2, transport.requests.size

    second = URI(transport.requests.last.url)
    params = URI.decode_www_form(second.query).to_h

    assert_equal({ "limit" => "2", "starting_after" => "c1", "workflow" => "welcome" }, params)
  end

  def test_api56_iteration_walks_every_page_and_stops
    transport = StubTransport.new(list(%w[ntf_1], "c1"), list(%w[ntf_2], nil))
    client, = TestSupport.client(transport)

    assert_equal(%w[ntf_1 ntf_2], client.list_notifications.map { |item| item["id"] })
    assert_equal 2, transport.requests.size
  end

  def test_api56_ending_before_walks_backwards_through_previous_cursor
    first = TestSupport.json(200, { "data" => [{ "id" => "ntf_2" }, { "id" => "ntf_1" }], "has_more" => true,
                                    "next_cursor" => "c3", "previous_cursor" => "c2" })
    second = TestSupport.json(200, { "data" => [{ "id" => "ntf_4" }, { "id" => "ntf_3" }], "has_more" => false,
                                     "next_cursor" => "c5", "previous_cursor" => nil })
    transport = StubTransport.new(first, second)
    client, = TestSupport.client(transport)

    assert_equal(%w[ntf_1 ntf_2 ntf_3 ntf_4], client.list_notifications(ending_before: "c0").map { |i| i["id"] })
    queries = transport.requests.map { |r| URI.decode_www_form(URI(r.url).query.to_s).to_h }

    assert_equal [{ "ending_before" => "c0" }, { "ending_before" => "c2" }], queries
  end

  def test_api56_a_page_without_more_has_no_next_page
    page = Esuiss::Relay::Page.new({ "data" => [], "has_more" => false, "next_cursor" => nil }) { raise "fetched" }

    assert_nil page.next_page
    assert_empty page.to_a
  end
end
