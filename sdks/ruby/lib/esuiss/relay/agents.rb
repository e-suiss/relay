# frozen_string_literal: true

require "securerandom"

module Esuiss
  module Relay
    # X-30
    # A waitpoint opened by #open_waitpoint with the Idempotency-Key that is its identity; sending
    # the same body with the same key again keeps its deadline.
    WaitpointHandle = Struct.new(:waitpoint, :idempotency_key, keyword_init: true) do
      def id
        waitpoint["id"]
      end
    end

    # X-30
    # Agent helpers: waitpoints, the durable mailbox and the stream-then-history pattern.
    module Agents
      TERMINAL_WAITPOINT_STATES = %w[resolved expired cancelled].freeze
      DURATION = /\AP(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?\z/

      def open_waitpoint(body, idempotency_key: nil, request_options: {})
        key = idempotency_key || SecureRandom.uuid
        WaitpointHandle.new(waitpoint: create_waitpoint(body, idempotency_key: key, request_options: request_options),
                            idempotency_key: key)
      end

      def await_waitpoint(waitpoint_id, timeout:, poll_interval: 2, heartbeat: true)
        deadline = @monotonic.call + timeout
        next_heartbeat = nil
        loop do
          waitpoint = get_waitpoint(waitpoint_id)
          return waitpoint if TERMINAL_WAITPOINT_STATES.include?(waitpoint["state"])

          now = @monotonic.call
          next_heartbeat = beat(waitpoint_id, waitpoint, now, next_heartbeat) if heartbeat
          remaining = deadline - now
          raise WaitTimeoutError, "waitpoint #{waitpoint_id} is still #{waitpoint['state']}" if remaining <= 0

          @sleeper.call([poll_interval, remaining].min)
        end
      end

      def read_mailbox(since: nil, limit: nil, &block)
        return enum_for(:read_mailbox, since: since, limit: limit) unless block

        cursor = since
        loop do
          page = list_mailbox_records(since: cursor, limit: limit)
          page.fetch("records", []).each(&block)
          cursor = page["cursor"]
          break unless page["has_more"] == true && cursor
        end
      end

      def lease_mailbox(max: 1)
        lease_mailbox_records({ "max" => max })
      end

      def ack_mailbox(lease_id, record_ids)
        ack_mailbox_records({ "lease_id" => lease_id, "record_ids" => Array(record_ids) })
      end

      def consume_mailbox(max: 10)
        lease = lease_mailbox(max: max)
        done = []
        begin
          lease.fetch("records", []).each do |record|
            yield record
            done << record["id"]
          end
        ensure
          ack_mailbox(lease["lease_id"], done) unless done.empty?
        end
        done.size
      end

      def merge_stream_and_history(stream, history, key: ->(item) { item["id"] },
                                   version: ->(item) { item["seq"] })
        StreamMerge.merge(stream, history, key: key, version: version)
      end

      def self.duration_seconds(text)
        match = DURATION.match(text.to_s)
        return nil unless match && text != "P" && text != "PT"

        days, hours, minutes, seconds = match.captures
        (days.to_i * 86_400) + (hours.to_i * 3600) + (minutes.to_i * 60) + seconds.to_f
      end

      private

      def beat(waitpoint_id, waitpoint, now, next_heartbeat)
        interval = Agents.duration_seconds(waitpoint["heartbeat_interval"])
        return next_heartbeat unless interval
        return next_heartbeat if next_heartbeat && now < next_heartbeat

        heartbeat_waitpoint(waitpoint_id)
        now + (interval / 2.0)
      end
    end

    # IN-28
    # AG-21
    # Opens the stream first, then lists the history, and yields each item once: an item whose
    # version is not above the highest version already yielded for its key is dropped.
    module StreamMerge
      module_function

      def merge(stream, history, key:, version:)
        Enumerator.new do |yielder|
          opened = stream.respond_to?(:call) ? stream.call : stream
          listed = history.respond_to?(:call) ? history.call : history
          seen = {}
          [listed, opened].each do |source|
            source.each { |item| yielder << item if fresh?(seen, key.call(item), version.call(item)) }
          end
        end
      end

      def fresh?(seen, id, version)
        if seen.key?(id)
          last = seen[id]
          return false if version.nil? || (!last.nil? && version <= last)
        end
        seen[id] = version
        true
      end
    end
  end
end
