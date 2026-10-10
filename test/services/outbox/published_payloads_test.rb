require "test_helper"

# What actually leaves this service, asserted rather than assumed.
#
# Every event type billing publishes is seeded through its real emission path —
# a model callback, a checkout, a signed webhook fixture — drained once against a
# broker double, and the delivered documents are read as a consumer would read
# them. Three properties, and the third is the one this packet is answerable for:
#
#   1. **The inventory.** The set of types that reach the bus is exactly
#      `OutboxEvent::TYPES`, each on the subject of its own type. A type that
#      never leaves is a dead letter; a type that leaves under another subject
#      is unroutable.
#   2. **The envelope.** Core's seven attributes and nothing else — the row's
#      own id, the type, this service as the source.
#   3. **No money event leaks.** A billing event must not carry a processor
#      secret, a card, or PII beyond what core's schema names. The payload is
#      the processor's own text for the description and this service's own rows
#      for the rest; both are asserted against a forbidden set and an allowed
#      PII key, because "it looks fine" is not an assertion.
class Outbox::PublishedPayloadsTest < ActiveSupport::TestCase
  setup do
    travel_to(frozen_now)
    @broker = FakeNatsBroker.new(stream_subjects: [ "billing.>" ]).start
    @transport = Outbox::NatsPublisher.build(@broker.url)
  end

  teardown do
    @transport&.close
    @broker&.shutdown
  end

  test "every event type billing publishes reaches the bus on its own subject, and carries no secret" do
    seed_customer_and_plan
    deliver_fixture("invoice.paid")
    deliver_fixture("invoice.payment_failed")
    deliver_fixture("customer.subscription.created")
    deliver_fixture("customer.subscription.updated")
    deliver_fixture("customer.subscription.deleted")
    @plan.update!(name: "Renamed")

    publisher = Cafaye::Outbox.publisher(
      connection: Cafaye::Outbox::ActiveRecordConnection.for(ActiveRecord::Base),
      clock: -> { Time.current },
      logger: nil,
      deliverer: ->(envelope) { @transport.publish(envelope) }
    )
    result = publisher.run_once

    # One pass, and every row the seed wrote leaves in it: the batch is the
    # whole table here, which is eight rows for eight types.
    assert_equal 8, result.claimed
    assert_equal 8, result.published

    envelopes = @broker.delivered.map { |message| JSON.parse(message.fetch(:payload)) }
    subjects = @broker.delivered.map { |message| message.fetch(:subject) }
    types = envelopes.map { |envelope| envelope.fetch("type") }

    # 1. The inventory: every published type, on its own subject, all of them
    #    billing's own.
    assert_equal OutboxEvent::TYPES.sort, types.sort,
      "the bus receives exactly the types this service declares"
    assert_equal types, subjects, "the subject is the event type — no mapping table, no rewriting"
    assert types.all? { |type| type.start_with?("billing.") },
      "a billing event type starts with its own name, or the billing.> stream does not cover it"
    assert_equal OutboxEvent::TYPES.size, envelopes.uniq { |e| e.fetch("type") }.size,
      "one delivery per type in this seed"

    envelopes.each do |envelope|
      # 2. The envelope: core's seven attributes, and the row's own id.
      assert_equal Set.new(%w[specversion id type source subject time data]), envelope.keys.to_set
      assert_equal "1.0", envelope.fetch("specversion")
      assert_equal "billing", envelope.fetch("source")
      assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, envelope.fetch("id"),
        "the envelope id is the row's uuid and the consumer's dedupe key")
    end

    # 3. No leak. Scanned over the whole delivered document, because a secret in
    #    any key is a leak regardless of which key it hides in.
    @broker.delivered.each do |message|
      document = message.fetch(:payload)
      assert_forbidden_values_absent(document)
      assert_no_forbidden_key(JSON.parse(document).fetch("data"))
    end

    # And the rows are marked, once, from the ack.
    assert_equal 0, OutboxEvent.unpublished.count
    assert_equal OutboxEvent.count, OutboxEvent.where.not(published_at: nil).count
  end

  private

    def seed_customer_and_plan
      @customer = Customer.create!(
        owner_type: "Account",
        owner_id: "11111111-1111-4111-8111-111111111111",
        processor: "stripe",
        processor_customer_id: "cus_R1pQKz9xLp2mN4vB6yH8jL0",
        email: "billing@example.com"
      )
      @plan = Plan.create!(
        name: "Pro Monthly",
        slug: "pro-monthly",
        price: Money.new(1900, "USD"),
        interval: "month",
        processor_price_id: "price_1PZQaBcDeFgHiJkLmNoPqR2"
      )
    end

    # The fixture, delivered as the webhook path delivers it: through ingestion,
    # with the body's own event id. This is the real writer for these five types.
    #
    # All at the suite's frozen instant on purpose: the assertions below are over
    # sets, not sequences, so a row ordering is not being proved and does not
    # need distinct instants — and a row written *ahead* of the publisher's
    # injected clock is a row the claim's schedule does not consider due yet,
    # which is a pass that silently claims three of the eight.
    def deliver_fixture(name)
      body = JSON.parse(stripe_fixture(name))
      Webhooks::Ingestion.new(processor: :stripe, event_id: body["id"], type: body["type"], payload: body).call
    end

    # Values that must never appear in a document this service puts on the bus.
    # The signing secret is the suite's own credential for nothing; the prefixes
    # are the processor's key shapes; the numbers are card tests.
    FORBIDDEN_VALUES = [
      "sk_live_", "sk_test_", "pk_live_", "whsec_",
      "4242424242424242", "4000000000000002", "5555555555554444"
    ].freeze

    # Keys that must never appear, under any payload, in any nesting. An id is
    # not a secret; these names are.
    FORBIDDEN_KEY = /secret|card|cvc|cvv|api[_-]?key|private|password|token/i

    # The one key that may hold PII, and the reason is core's: the money-event
    # schemas name `email` because a consumer cannot look it up anywhere else.
    ALLOWED_PII_KEYS = %w[email].freeze

    def assert_forbidden_values_absent(document)
      FORBIDDEN_VALUES.each do |value|
        refute_includes document, value,
          "a delivered document carries #{value.inspect}; a processor secret or a card reached the bus"
      end
    end

    def assert_no_forbidden_key(data, path = "data")
      case data
      when Hash
        data.each do |key, value|
          refute_match FORBIDDEN_KEY, key.to_s,
            "#{path} carries a key named #{key.inspect}; that is a secret's shape on the bus"
          assert_no_forbidden_key(value, "#{path}.#{key}")
        end
      when Array
        data.each_with_index { |entry, index| assert_no_forbidden_key(entry, "#{path}[#{index}]") }
      when String
        nil
      end
    end

    # Every key anywhere in every payload that could hold PII is one core names.
    # `email` is the whole of it; anything else is this service inventing a
    # consumer's lookup.
    test "the only PII a payload carries is the email core names" do
      seed_customer_and_plan
      deliver_fixture("invoice.paid")

      publisher = Cafaye::Outbox.publisher(
        connection: Cafaye::Outbox::ActiveRecordConnection.for(ActiveRecord::Base),
        clock: -> { Time.current },
        logger: nil,
        deliverer: ->(envelope) { @transport.publish(envelope) }
      )
      publisher.run_once

      pii_keys = []
      @broker.delivered.each do |message|
        collect_pii_keys(JSON.parse(message.fetch(:payload)).fetch("data"), pii_keys)
      end

      assert_equal [ "email", "name", "owner" ].sort, pii_keys.uniq.sort,
        "the recipient fact core names, the plan's display name and the owner's " \
        "type-and-uuid are the whole of it — no address, phone, or personal name"
    end

    def collect_pii_keys(data, into)
      case data
      when Hash
        data.each do |key, value|
          into << key.to_s if key.to_s.match?(/mail|address|phone|ssn|dob|name|owner/i)
          collect_pii_keys(value, into)
        end
      when Array
        data.each { |entry| collect_pii_keys(entry, into) }
      end
    end
end
