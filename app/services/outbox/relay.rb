# frozen_string_literal: true

module Outbox
  # The drain loop: one pass a second, until the process stops.
  #
  # The pass itself is the shared gem's — claim a batch with
  # `for update skip locked`, publish each row, mark it from the broker's ack,
  # and never let one row stop the batch. This class is the loop around it and
  # the process wiring, and it exists because the gem deliberately stops at the
  # transport boundary: it has no clock loop, no thread and no boot condition,
  # because those are the service's.
  #
  # ## The poll is fixed, and that is the decision
  #
  # `POLL_INTERVAL` is one second and does not grow. A backoff that grows while
  # idle leaves a newly created subscription's event sitting unpublished for
  # minutes, and a newly created event is the common case. The cost of the
  # simple version is one cheap indexed query per second, which is nothing
  # against the write traffic this service already takes. (The gem's *per-row*
  # backoff is a different schedule for a different thing: it delays only rows
  # that have already failed, so a broker outage does not turn into a hot loop
  # against a broker that is already down, while a fresh row is still due
  # immediately.)
  #
  # ## The loop is tied to the process
  #
  # One thread, started by the initializer when `NATS_URL` is set and stopped by
  # `#stop` from an `at_exit`. It is a daemon-shaped thread in the sense that it
  # does not keep a dead process alive, and it is bounded: `stop` asks the loop
  # to finish its current pass and join it. A pass in flight when the process
  # exits leaves its rows unpublished — which is correct, because the marks are
  # in the same transaction as the publish, and an unmarked row is a row the
  # next pass picks up again with the same envelope id.
  class Relay
    # Identity's `DefaultPollInterval`, matched. Pinned rather than derived
    # because a schedule nobody can read is a schedule nobody can tune, and a
    # test asserts this constant is what the loop actually waits.
    POLL_INTERVAL = 1.0

    # How long `stop` waits for the loop to finish its pass before giving up on
    # the join. A publish is bounded by `NatsPublisher::PUBLISH_TIMEOUT`, so a
    # full batch against a silent broker can legitimately take longer than this
    # — the join gives up, the thread finishes or dies with the process, and the
    # rows stay unpublished either way.
    JOIN_TIMEOUT = 5

    # Starts the loop against the broker at `url`.
    #
    # A broker that is down is not a startup failure: the loop starts, every
    # publish fails while it is down, the rows stay claimable, and they drain
    # when it returns. A URL that does not parse *is* a failure — see
    # `NatsPublisher`.
    def self.start(url:, logger: nil, poll_interval: POLL_INTERVAL)
      transport = NatsPublisher.build(url, logger: logger)
      relay = new(build_publisher(transport, logger: logger), transport: transport, logger: logger,
        poll_interval: poll_interval)
      relay.start
      relay
    end

    # The process wiring, as a seam the initializer calls and a test can drive
    # without touching the environment of the process it runs in.
    #
    # Without a broker, nothing starts: `NoopPublisher` exists in identity and
    # is never wired, and nothing like it is wired here either. Marking every
    # event published and draining the outbox into nowhere is worse than the
    # honest accumulation an unconfigured broker produces — the rows are the
    # promise, and a promise kept by discarding is not a promise. The boot log
    # says which state the deployment is in.
    #
    # @param env [Hash] the environment. `ENV` in production, a hash in tests.
    # @return [Relay, nil] the running loop, or nil when there is no broker.
    def self.start_from_environment(env: ENV.to_h, logger: nil)
      url = env["NATS_URL"].to_s.strip
      if url.empty?
        logger&.info("NATS_URL is not set; the outbox publisher is not started, and events will " \
                     "accumulate in outbox_events until a broker is configured")
        return nil
      end

      relay = start(url: url, logger: logger)
      logger&.info("the outbox publisher is running against #{url}")
      relay
    end

    def initialize(publisher, transport:, logger: nil, poll_interval: POLL_INTERVAL)
      @publisher = publisher
      @transport = transport
      @logger = logger
      @poll_interval = duration(poll_interval, "poll_interval")
      @stop = Queue.new
      @mutex = Mutex.new
      @thread = nil
    end

    attr_reader :publisher, :transport, :poll_interval

    # One pass, synchronously. The loop's body, and the test's way to drain the
    # outbox without a clock: claim, publish, mark, return.
    def run_once
      @publisher.run_once
    end

    def running?
      # The thread reference is read without the mutex: a single ivar read is
      # atomic, and `start` calls this while already holding the lock — a
      # reentrant lock is a deadlock in Ruby.
      thread = @thread
      !thread.nil? && thread.alive? && !stopping?
    end

    def start
      return self if running?

      @mutex.synchronize do
        return self if running?

        @thread = Thread.new { loop_body }
        @thread.name = "outbox-relay"
      end
      self
    end

    # Asks the loop to stop and waits for it. Idempotent, and safe to call from
    # an `at_exit` in a process that never started.
    def stop
      @stop.close
      thread = @mutex.synchronize { @thread }
      thread&.join(JOIN_TIMEOUT)
      @transport.close
      self
    end

    private

      def loop_body
        until stopping?
          pass = run_once
          # A full batch may mean there is more waiting, so a pass that moved
          # something does not wait out the interval — the same rule identity's
          # `Run` states as `continue` on a non-zero count.
          next if pass && pass.published.to_i.positive?

          break if wait_for_interval
        end
      rescue StandardError => error
        # The pass itself failed — the claim, the connection, the transaction.
        # Nothing was marked, because the marks are inside the pass's
        # transaction, so every row is still claimable and the next pass starts
        # from the same place. Logged with the class and nothing else: the
        # payload is the one part of an envelope that can carry a value.
        @logger&.warn("outbox: the publish pass failed; retrying (#{error.class})")
        retry unless stopping?
      end

      # Waits out the interval, and reports whether the wait ended in a stop.
      #
      # `pop(timeout:)` answers `nil` on a timeout and on a closed queue alike,
      # so the question "was I stopped" is asked of the queue's state rather
      # than of the return value — which is also the honest place for it, since
      # closing the queue *is* the stop signal.
      def wait_for_interval
        @stop.pop(timeout: @poll_interval)
        stopping?
      end

      def stopping?
        @stop.closed?
      end

      # A poll interval is a duration, not a count: a Numeric above zero. The
      # tests use fractions of a second, and a check that only accepted integers
      # would refuse the very schedule the loop's own constant sets.
      def duration(value, field)
        unless value.is_a?(Numeric) && value.positive? && value.finite?
          raise Outbox::ConfigurationError, "#{field} must be a number of seconds > 0"
        end

        value
      end

      # The shared gem's publisher, over billing's Active Record connection.
      # The deliverer is the transport, and the clock is injected because a loop
      # that evaluated its schedule against a different clock than the one it
      # inserts timestamps with is a loop whose backoff is a function of clock
      # skew.
      def self.build_publisher(transport, logger:)
        Anywaye::Outbox.publisher(
          connection: Anywaye::Outbox::ActiveRecordConnection.for(ActiveRecord::Base),
          clock: -> { Time.current },
          logger: logger,
          deliverer: ->(envelope) { transport.publish(envelope) }
        )
      end
  end
end
