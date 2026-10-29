require "test_helper"

class Outbox::NatsPublisherTest < ActiveSupport::TestCase
  setup do
    travel_to(frozen_now)
    @broker = FakeNatsBroker.new(stream_subjects: [ "billing.>" ]).start
  end

  teardown do
    @broker&.shutdown
  end

  test "a row reaches the broker on the subject of its type, carrying the row's own envelope" do
    customer = create_customer
    row = OutboxEvent.sole

    publisher = Anywaye::Outbox.publisher(
      connection: Anywaye::Outbox::ActiveRecordConnection.for(ActiveRecord::Base),
      clock: -> { Time.current },
      logger: nil,
      deliverer: ->(envelope) { Outbox::NatsPublisher.build(@broker.url).publish(envelope) }
    )

    assert_nil row.reload.published_at

    result = publisher.run_once

    assert_equal 1, result.published

    delivered = @broker.delivered
    assert_equal 1, delivered.size

    message = delivered.sole
    assert_equal "billing.customer.created", message.fetch(:subject)

    envelope = JSON.parse(message.fetch(:payload))
    assert_equal Set.new(%w[specversion id type source subject time data]), envelope.keys.to_set,
      "the delivered document is core's seven attributes and nothing else"
    assert_equal "1.0", envelope.fetch("specversion")
    assert_equal row.id, envelope.fetch("id"), "the row's primary key is the envelope's dedupe key"
    assert_equal "billing.customer.created", envelope.fetch("type")
    assert_equal "billing", envelope.fetch("source")
    assert_equal row.subject, envelope.fetch("subject"), "the entity, not the type"
    assert_equal customer.email, envelope.fetch("data").fetch("email")

    assert_not_nil row.reload.published_at
    assert_equal 0, row.attempts
  end

  test "a refusal leaves the row claimable" do
    silent_broker = FakeNatsBroker.new(stream_subjects: []).start
    create_customer
    row = OutboxEvent.sole

    publisher = Anywaye::Outbox.publisher(
      connection: Anywaye::Outbox::ActiveRecordConnection.for(ActiveRecord::Base),
      clock: -> { Time.current },
      logger: nil,
      deliverer: ->(envelope) { Outbox::NatsPublisher.build(silent_broker.url).publish(envelope) }
    )

    result = publisher.run_once

    assert_equal 0, result.published
    assert_nil row.reload.published_at, "a refused publish is not a delivery"
    assert_equal 1, row.attempts, "an operator watching attempts climb is the alert"
    assert_equal 1, Anywaye::Outbox::ActiveRecordConnection.for(ActiveRecord::Base).claim_batch(
      limit: 10, max_attempts: 10, max_backoff: 300, now: Time.current + 1.second
    ).size, "the row is still claimable, so the retry is real"
  ensure
    silent_broker&.shutdown
  end

  test "a silent broker leaves the row claimable" do
    quiet_broker = FakeNatsBroker.new(stream_subjects: [ "billing.>" ], mode: :silent).start
    create_customer
    row = OutboxEvent.sole

    transport = Outbox::NatsPublisher.build(quiet_broker.url, publish_timeout: 1)
    publisher = Anywaye::Outbox.publisher(
      connection: Anywaye::Outbox::ActiveRecordConnection.for(ActiveRecord::Base),
      clock: -> { Time.current },
      logger: nil,
      deliverer: ->(envelope) { transport.publish(envelope) }
    )

    result = publisher.run_once

    assert_equal 0, result.published
    assert_nil row.reload.published_at
    assert_equal 1, row.attempts
  ensure
    quiet_broker&.shutdown
  end

  test "a republished row carries the same envelope id" do
    transport = Outbox::NatsPublisher.build(@broker.url)
    envelope = {
      "specversion" => "1.0",
      "id" => SecureRandom.uuid,
      "type" => "billing.subscription.started",
      "source" => "billing",
      "subject" => SecureRandom.uuid,
      "time" => Time.current.utc.iso8601,
      "data" => { "status" => "active" }
    }

    transport.publish(envelope)
    transport.publish(envelope)

    first, second = @broker.delivered
    assert_equal first.fetch(:payload), second.fetch(:payload), "the duplicate is byte-identical"
    assert_equal JSON.parse(first.fetch(:payload)).fetch("id"), JSON.parse(second.fetch(:payload)).fetch("id")
  end

  test "a broker that is down at boot is an outage, not a boot failure" do
    transport = Outbox::NatsPublisher.build("nats://127.0.0.1:1", connect_timeout: 1, publish_timeout: 1)
    create_customer
    row = OutboxEvent.sole

    publisher = Anywaye::Outbox.publisher(
      connection: Anywaye::Outbox::ActiveRecordConnection.for(ActiveRecord::Base),
      clock: -> { Time.current },
      logger: nil,
      deliverer: ->(envelope) { transport.publish(envelope) }
    )
    result = publisher.run_once

    assert_equal 0, result.published
    assert_nil row.reload.published_at
    assert_equal 1, row.attempts
  end

  test "a URL that does not parse is refused at construction" do
    assert_raises(Outbox::ConfigurationError) { Outbox::NatsPublisher.build("nats://\x7f") }
    assert_raises(Outbox::ConfigurationError) { Outbox::NatsPublisher.build("") }
    assert_raises(Outbox::ConfigurationError) { Outbox::NatsPublisher.build("nats://") }
  end

  test "a type that is not this service's own is refused before the wire" do
    transport = Outbox::NatsPublisher.build(@broker.url)
    envelope = {
      "specversion" => "1.0",
      "id" => SecureRandom.uuid,
      "type" => "identity.user.created",
      "source" => "identity",
      "subject" => SecureRandom.uuid,
      "time" => Time.current.utc.iso8601,
      "data" => {}
    }

    assert_raises(Outbox::Error) { transport.publish(envelope) }
    assert_empty @broker.delivered, "a foreign type never reaches the bus from here"
  end

  private

    def create_customer
      Customer.create!(
        owner_type: "Account",
        owner_id: "11111111-1111-4111-8111-111111111111",
        processor: "stripe",
        processor_customer_id: "cus_R1pQKz9xLp2mN4vB6yH8jL0",
        email: "billing@example.com"
      )
    end
end
