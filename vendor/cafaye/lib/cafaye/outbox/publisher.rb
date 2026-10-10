# frozen_string_literal: true

module Cafaye
  module Outbox
    # Moves committed rows to a transport.
    #
    # A separate loop, in a separate process or worker, never in a request path.
    # It never sleeps on behalf of a request. What it does, per core's
    # `docs/event-outbox.md`:
    #
    # - claims a batch with `for update skip locked`, so N replicas can run it
    #   against one table;
    # - publishes in `created_at` order, with `id` as the tiebreaker, so a slow
    #   batch cannot publish event 2 before event 1;
    # - marks `published_at` **from the transport's acknowledgement**, never
    #   before, so a publish that was never acknowledged is an unpublished row and
    #   the next pass republishes it;
    # - increments `attempts` on failure and backs off exponentially, so a
    #   broker outage is not turned into a hot loop against a broker that is
    #   already down;
    # - leaves a row alone past `max_attempts`, because an event stuck for an
    #   hour is an incident to alert on and an event dropped silently is a
    #   mystery.
    #
    # Delivery is **at-least-once** and this is a contract with consumers rather
    # than a limitation to paper over. The publisher's half of the contract is
    # that a redelivery carries the *same* envelope `id`, so a consumer that
    # dedupes on it sees one event.
    class Publisher
      # The default batch. core says 100-500; this is the low end because a
      # smaller batch holds fewer row locks for less time, and the cost of a
      # small batch is one extra query rather than a stalled table.
      DEFAULT_BATCH_SIZE = 100

      # Attempts before a row is left alone. core: cap it, alert, leave it.
      DEFAULT_MAX_ATTEMPTS = 10

      # The backoff ceiling, in seconds. core: "capped at a few minutes".
      DEFAULT_MAX_BACKOFF = 300

      # What one pass did. Frozen, and it carries the ids so a caller can log
      # exactly which events moved without re-reading the table.
      Result = Struct.new(:claimed, :published, :failed, :ids, keyword_init: true) do
        def initialize(claimed: 0, published: 0, failed: 0, ids: [])
          super
          freeze
        end
      end

      # @param deliverer [#call, nil] receives one envelope hash and returns when
      #   the transport has acknowledged it. Raising is how it refuses. It is the
      #   only thing this class does not own, and it is the only thing a service
      #   has to write to get events onto a bus — a default of `nil` rather than
      #   a required keyword so that a publisher built without one fails as a
      #   configuration error here, where the message can say what is missing.
      def initialize(connection:, deliverer: nil, clock: -> { Time.now }, logger: nil,
                     batch_size: DEFAULT_BATCH_SIZE, max_attempts: DEFAULT_MAX_ATTEMPTS,
                     max_backoff: DEFAULT_MAX_BACKOFF)
        @connection = connection
        @deliverer = deliverer || reject("deliverer is required: the publisher has nowhere to deliver to")
        @clock = clock
        @logger = logger
        @batch_size = positive(batch_size, "batch_size")
        @max_attempts = positive(max_attempts, "max_attempts")
        @max_backoff = positive(max_backoff, "max_backoff")
      end

      attr_reader :batch_size, :max_attempts, :max_backoff

      # One pass: claim, deliver, mark, commit.
      #
      # The transaction is short — claim, publish, mark, commit — and that is
      # deliberate. Holding row locks across a network call is what turns a
      # broker hiccup into a database one, and the rows stay unpublished, which
      # is correct, but the whole table stops moving while it happens.
      def run_once(batch_size: @batch_size, max_attempts: @max_attempts, max_backoff: @max_backoff)
        limit = positive(batch_size, "batch_size")
        cap = positive(max_attempts, "max_attempts")
        ceiling = positive(max_backoff, "max_backoff")

        @connection.transaction do
          claimed = @connection.claim_batch(limit: limit, max_attempts: cap, max_backoff: ceiling, now: @clock.call)
          next Result.new if claimed.empty?

          deliver_batch(claimed)
        end
      rescue Errors::Error
        # This library's own errors are answers, not failures to be wrapped. A
        # caller rescuing `DeliveryFailed` must not catch a configuration
        # problem that happened to be raised inside the pass.
        raise
      rescue StandardError => error
        # The batch itself failed — the claim query, the connection, the
        # transaction. Nothing was marked, because the marks are in the same
        # transaction, so every row is still claimable and the next pass starts
        # from the same place. A caller that supervises this loop wants to hear
        # about it: a per-row publish failure is counted and logged, but a
        # batch that cannot even be claimed is an outage.
        raise Errors::Outbox::DeliveryFailed, "the publish pass failed (#{error.class})"
      end

      # The wait before a row at `attempts` is retried.
      #
      # Zero attempts is due immediately — a row that has never been published
      # has never been tried, and holding the first attempt for a second delays
      # every event in the fleet by a second for no reason. After one failure the
      # wait is one second, then two, then four, capped at `max_backoff`.
      #
      # Public because a service needs it for its alerting, and public because a
      # schedule nobody can read is a schedule nobody can tune. The same
      # arithmetic is in `PgConnection::CLAIM_SQL`, because a schedule that
      # exists in two places is a schedule that will differ in two places.
      def backoff_seconds(attempts)
        return 0 if attempts.to_i < 1

        [ 2**(attempts.to_i - 1), max_backoff ].min
      end

      private

      # Deliver, then mark, per row, and never let one row stop the batch.
      #
      # core: "A consumer that cannot process an event must not block the queue:
      # park it, alert, keep going." The same is true of the publisher's own
      # failures — a transport that is refusing one message should not stop the
      # other ninety-nine in the batch from reaching it, and a single malformed
      # row should not wedge the loop for the whole service.
      def deliver_batch(claimed)
        published = 0
        failed = 0

        claimed.each do |row|
          # Ack, then mark: `published_at` is set only after the deliverer has
          # returned, and never before.
          if deliver(row)
            @connection.mark_published(row.id)
            published += 1
          else
            @connection.mark_failed(row.id)
            failed += 1
          end
        end

        Result.new(claimed: claimed.size, published: published, failed: failed, ids: claimed.map(&:id))
      end

      # @return [true] the transport acknowledged, [false] it refused.
      def deliver(row)
        @deliverer.call(row.to_h)
        true
      rescue StandardError => error
        # The message names the event and its subject and nothing else. A failed
        # publish is exactly the log line an operator reads, so it has to be
        # useful — and the payload is the one part of an envelope that can carry
        # an email address, so it stays out.
        log_failure(row, error)
        false
      end

      def log_failure(row, error)
        return if @logger.nil?

        @logger.warn("outbox: could not deliver #{row.event_type} for #{row.subject} (#{error.class})")
      end

      def positive(value, field)
        raise Errors::ConfigurationError, "#{field} must be an integer >= 1" unless value.is_a?(Integer) && value >= 1

        value
      end

      def reject(message)
        raise Errors::ConfigurationError, message
      end
    end
  end
end
