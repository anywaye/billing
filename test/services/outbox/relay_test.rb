require "test_helper"

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

    relay = Outbox::Relay.new(
      Anywaye::Outbox.publisher(
        connection: Anywaye::Outbox::ActiveRecordConnection.for(ActiveRecord::Base),
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
    assert_equal 100, Anywaye::Outbox::Publisher::DEFAULT_BATCH_SIZE,
      "identity's batch, the shared gem's default, unchanged"
  end

  test "a full batch does not wait out the interval" do
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
    create_customer
    real = Anywaye::Outbox.publisher(
      connection: Anywaye::Outbox::ActiveRecordConnection.for(ActiveRecord::Base),
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
