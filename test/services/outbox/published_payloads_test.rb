require "test_helper"

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

    publisher = Anywaye::Outbox.publisher(
      connection: Anywaye::Outbox::ActiveRecordConnection.for(ActiveRecord::Base),
      clock: -> { Time.current },
      logger: nil,
      deliverer: ->(envelope) { @transport.publish(envelope) }
    )
    result = publisher.run_once

    assert_equal OutboxEvent::TYPES.size, result.claimed
    assert_equal OutboxEvent::TYPES.size, result.published
    assert_equal OutboxEvent::TYPES.size, OutboxEvent.count,
      "the seed wrote exactly one row per type — a type with two rows, or a type " \
      "with none, fails here rather than in the assertions below"

    envelopes = @broker.delivered.map { |message| JSON.parse(message.fetch(:payload)) }
    subjects = @broker.delivered.map { |message| message.fetch(:subject) }
    types = envelopes.map { |envelope| envelope.fetch("type") }

    assert_equal OutboxEvent::TYPES.sort, types.sort,
      "the bus receives exactly the types this service declares"
    assert_equal types, subjects, "the subject is the event type — no mapping table, no rewriting"
    assert types.all? { |type| type.start_with?("billing.") },
      "a billing event type starts with its own name, or the billing.> stream does not cover it"
    assert_equal OutboxEvent::TYPES.size, envelopes.uniq { |e| e.fetch("type") }.size,
      "one delivery per type in this seed"

    envelopes.each do |envelope|
      assert_equal Set.new(%w[specversion id type source subject time data]), envelope.keys.to_set
      assert_equal "1.0", envelope.fetch("specversion")
      assert_equal "billing", envelope.fetch("source")
      assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, envelope.fetch("id"),
        "the envelope id is the row's uuid and the consumer's dedupe key")
    end

    @broker.delivered.each do |message|
      document = message.fetch(:payload)
      assert_forbidden_values_absent(document)
      assert_no_forbidden_key(JSON.parse(document).fetch("data"))
    end

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
        price: Billing::Money.new(1900, "USD"),
        interval: "month",
        processor_price_id: "price_1PZQaBcDeFgHiJkLmNoPqR2"
      )
    end

    def deliver_fixture(name)
      body = JSON.parse(stripe_fixture(name))
      Webhooks::Ingestion.new(processor: :stripe, event_id: body["id"], type: body["type"], payload: body).call
    end

    FORBIDDEN_VALUES = [
      "sk_live_", "sk_test_", "pk_live_", "whsec_",
      "4242424242424242", "4000000000000002", "5555555555554444"
    ].freeze

    FORBIDDEN_KEY = /secret|card|cvc|cvv|api[_-]?key|private|password|token/i

    ALLOWED_PII_KEYS = %w[email].freeze

    NON_PII_NAME_KEYS = %w[name plan_name owner].freeze

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

    test "the only PII a payload carries is the email core names" do
      seed_customer_and_plan
      deliver_fixture("invoice.paid")
      deliver_fixture("invoice.payment_failed")
      deliver_fixture("customer.subscription.created")
      deliver_fixture("customer.subscription.updated")
      deliver_fixture("customer.subscription.deleted")
      @plan.update!(name: "Renamed")

      publisher = Anywaye::Outbox.publisher(
        connection: Anywaye::Outbox::ActiveRecordConnection.for(ActiveRecord::Base),
        clock: -> { Time.current },
        logger: nil,
        deliverer: ->(envelope) { @transport.publish(envelope) }
      )
      publisher.run_once

      assert_equal OutboxEvent::TYPES.size, @broker.delivered.size,
        "the pass delivered every type this service publishes, so the PII scan " \
        "below is over the whole bus and not over a short list"

      pii_keys = []
      @broker.delivered.each do |message|
        collect_pii_keys(JSON.parse(message.fetch(:payload)).fetch("data"), pii_keys)
      end

      assert_equal (ALLOWED_PII_KEYS + NON_PII_NAME_KEYS).sort, pii_keys.uniq.sort,
        "the recipient fact core names, the plan's display text and the owner's " \
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
