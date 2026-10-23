require "test_helper"

# The transport, and one publish pass through the shared gem's publisher, against
# an in-process broker: the subject a row is published on, the envelope bytes that
# arrive, and the row's columns after the broker acks or refuses.
#
# The behaviour under test IS the wire. `Outbox::NatsPublisher` is the only piece
# of billing that knows a broker exists, so these files are where a second
# mechanism would show up: the claim is the gem's, the loop is `Relay`'s, and
# this is the deliverer — one method, asserted against a real socket.
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

    # The row is unpublished before the pass. The row is the promise, and the
    # promise is not kept until the broker acks.
    assert_nil row.reload.published_at

    result = publisher.run_once

    assert_equal 1, result.published

    delivered = @broker.delivered
    assert_equal 1, delivered.size

    message = delivered.sole
    # The subject is the event type — core's "no mapping table, no prefix
    # rewriting" — and not the envelope's `subject` attribute, which is the
    # entity the event is about.
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

    # And only now is the row marked: the mark is downstream of the ack, so a
    # set `published_at` is a set the broker has seen.
    assert_not_nil row.reload.published_at
    assert_equal 0, row.attempts
  end

  test "a refusal leaves the row claimable" do
    # No stream covers anything: this is what a stack that defines no `billing.>`
    # stream produces, and the direction it must fail in.
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
    # The broker that neither acks nor refuses — a half-configured stream. The
    # publish budget turns the silence into a failure, and the failure is the
    # row's claimability.
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
    # At-least-once means a duplicate is survivable, and it is survivable only
    # because the envelope id is a function of the row and not of the publish:
    # the crash between the ack and the mark re-claims the same row, and the
    # consumer's dedupe key actually dedupes.
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
    # A port with nothing listening. The transport is built (no raise), and the
    # publish fails — which leaves the row claimable until the broker is back.
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
