# frozen_string_literal: true

module Esuiss
  module Relay
    # API-56
    # One page of a cursor-paginated list. Enumerating it walks every item of every following page,
    # fetching the next page only when the items before it are used up.
    class Page
      include Enumerable

      attr_reader :raw

      def initialize(raw, &fetch_next)
        @raw = raw.is_a?(Hash) ? raw : {}
        @fetch_next = fetch_next
      end

      def data
        Array(@raw["data"])
      end

      def more?
        @raw["has_more"] == true
      end

      def next_cursor
        @raw["next_cursor"]
      end

      def previous_cursor
        @raw["previous_cursor"]
      end

      def next_page
        return nil unless more? && next_cursor.is_a?(String) && !next_cursor.empty? && @fetch_next

        @fetch_next.call(next_cursor)
      end

      def each(&block)
        return enum_for(:each) unless block

        each_page { |page| page.data.each(&block) }
        self
      end

      def each_page
        return enum_for(:each_page) unless block_given?

        page = self
        while page
          yield page
          page = page.next_page
        end
        self
      end
    end
  end
end
