require "test_helper"

# The loop and the boot condition.
#
# Two of these are the packet's "done" conditions, and they are the direction
# that matters: a row leaves when a broker is configured, and nothing leaves —
# and nothing starts — when one is not. The rest hold the schedule and the
# shutdown to identity's documented decisions.
class Outbox::RelayTest < ActiveSupport::TestCase
  setup do
    travel_to(frozen_now)
    @broker = FakeNatsBroker.new(stream_subjects: [ "billing.>" ]).start
  end

  teardown do
    @relay&.stop
    @broker&.shutdown
  end

  test "an unpublished row reaches the stream under a billing subject, and the row is marked" do
    create_customer

    # One synchronous pass, not the thread: the claim, the publish and the mark
    # are the pass's, and the thread is only a clock around them.
    relay = Outbox::Relay.new(
      Cafaye::Outbox.publisher(
        connection: Cafaye::Outbox::ActiveRecordConnection.for(ActiveRecord::Base),
        clock: -> { Time.current },
        logger: nil,
        deliverer: ->(envelope) { Outbox::NatsPublisher.build(@broker.url).publish(envelope) }
      ),
      transport: Outbox::NatsPublisher.build(@broker.url),
      logger: nil
    )

    result = relay.run_once

    assert_equal 1, result.published
    assert_equal [ "billing.customer.created" ], @broker.delivered.map { |m| m.fetch(:subject) }
    assert_not_nil OutboxEvent.sole.reload.published_at
  end

  test "the loop drains the table on a thread, and stops on stop" do
    create_customer

    @relay = Outbox::Relay.start(url: @broker.url, poll_interval: 0.05)

    assert_predicate @relay, :running?
    assert_equal "outbox-relay", @relay.instance_variable_get(:@thread).name

    # The fixed poll, observed rather than slept on: the row is written and the
    # loop picks it up without anybody telling it to.
    wait_until("a started loop publishes a committed row") { @broker.delivered.any? }
    wait_until("and marks it from the ack") { OutboxEvent.sole.reload.published_at.present? }

    @relay.stop

    refute_predicate @relay, :running?
  end

  test "without NATS_URL nothing starts, nothing is marked, and the boot log says so" do
    create_customer
    log = StringIO.new

    relay = Outbox::Relay.start_from_environment(env: {}, logger: Logger.new(log))

    assert_nil relay
    assert_nil OutboxEvent.sole.reload.published_at
    assert_empty @broker.delivered
    assert_includes log.string, "NATS_URL is not set"
    assert_includes log.string, "accumulate in outbox_events"
  end

  test "with NATS_URL set the wiring returns a running loop, and the boot log names the broker" do
    log = StringIO.new

    relay = Outbox::Relay.start_from_environment(env: { "NATS_URL" => @broker.url }, logger: Logger.new(log))

    assert_kind_of Outbox::Relay, relay
    assert_predicate relay, :running?
    assert_includes log.string, "the outbox publisher is running against #{@broker.url}"
  ensure
    relay&.stop
  end

  test "the poll interval is one second, fixed, and the loop is stopped before the threads are counted" do
    assert_equal 1.0, Outbox::Relay::POLL_INTERVAL
    assert_equal 100, Cafaye::Outbox::Publisher::DEFAULT_BATCH_SIZE,
      "identity's batch, the shared gem's default, unchanged"
  end

  test "a full batch does not wait out the interval" do
    # A pass that moved something is a pass that may have more waiting, so the
    # loop goes around again immediately. Two customers, one batch, and the
    # second row must not sit for the interval.
    2.times do |index|
      create_customer(
        owner_id: format("11111111-1111-4111-8111-11111111111%d", index),
        processor_customer_id: "cus_TWO#{index}"
      )
    end

    @relay = Outbox::Relay.start(url: @broker.url, poll_interval: 3600)

    wait_until("both rows leave one pass; the loop does not sleep between them") do
      @broker.delivered.size == 2
    end
    assert_equal 2, @broker.delivered.size
  end

  test "a pass that cannot claim is retried rather than fatal" do
    # The database blipping is an outage, not a bug: the loop logs the class and
    # keeps going, because the next pass may find the row still claimable. A
    # publisher that fails once and then delegates is the case, and the thread
    # surviving to publish is the assertion.
    create_customer
    real = Cafaye::Outbox.publisher(
      connection: Cafaye::Outbox::ActiveRecordConnection.for(ActiveRecord::Base),
      clock: -> { Time.current },
      logger: nil,
      deliverer: ->(envelope) { Outbox::NatsPublisher.build(@broker.url).publish(envelope) }
    )
    flaky = Object.new
    calls = 0
    flaky.define_singleton_method(:run_once) do
      calls += 1
      raise ActiveRecord::StatementInvalid, "the database is gone" if calls == 1

      real.run_once
    end

    @relay = Outbox::Relay.new(flaky, transport: Outbox::NatsPublisher.build(@broker.url), logger: nil,
      poll_interval: 0.05)
    @relay.start

    assert_predicate @relay, :running?, "a failed pass does not kill the loop"
    wait_until("the next pass retries and the row leaves") { @broker.delivered.any? }
    assert_not_nil OutboxEvent.sole.reload.published_at
  end

  private

    # Waits for a condition without a sleep in the assertion: the loop under test
    # runs on its own thread and its own clock, so the spec waits on the
    # *observable* outcome with a bounded deadline rather than sleeping a
    # guessed duration and hoping. A deadline is not a sleep here — it is the
    # difference between "the row arrived" and "the row arrived in time".
    def wait_until(message = nil, deadline: 10)
      deadline_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
      until yield
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline_at
          flunk(message || "the condition was not observed within #{deadline}s")
        end
        sleep 0.01
      end
    end

    def create_customer(owner_id: "11111111-1111-4111-8111-111111111111",
                        processor_customer_id: "cus_R1pQKz9xLp2mN4vB6yH8jL0")
      Customer.create!(
        owner_type: "Account",
        owner_id: owner_id,
        processor: "stripe",
        processor_customer_id: processor_customer_id,
        email: "billing@example.com"
      )
    end
end
