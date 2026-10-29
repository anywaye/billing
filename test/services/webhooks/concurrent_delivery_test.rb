require "test_helper"

class Webhooks::ConcurrentDeliveryTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  INVOICE_PAID = "invoice.paid".freeze
  DUPLICATE_REASON = "ignored:duplicate_delivery".freeze

  setup do
    travel_to(frozen_now)
    clear_written_tables
  end

  teardown do
    clear_written_tables
  end


  test "two simultaneous deliveries of one event id emit one event" do
    deliver_twice_at_once

    assert_equal 1, outbox_rows,
      "one Stripe event id produced #{outbox_rows} outbox rows. Two rows are " \
      "two envelope ids, and core's envelope id is the dedupe key — a consumer " \
      "cannot tell the second from new information about the same charge."
  end

  test "the event that survives is the payment, and it names the processor event once" do
    deliver_twice_at_once

    event = OutboxEvent.sole
    assert_equal "billing.payment.succeeded", event.event_type
    assert_equal [ "evt_1PZQaBcDeFgHiJkLmNoPqR4" ],
      event.data.values_at("processor_event_id")
  end

  test "the delivery is finished, and is not parked for a human" do
    deliver_twice_at_once

    row = ProcessorWebhook.sole
    assert_predicate row.processed_at, :present?,
      "processed_at is null, so the next delivery treats this as unfinished and redoes it"
    refute row.failed?,
      "a duplicate delivery is a decision, not a failure. Parked as failed:#{row.error}"
  end

  test "the delivery that lost records why, so a human can query it" do
    records = deliver_twice_at_once
    errors = records.map(&:error)

    assert_equal 1, errors.count(DUPLICATE_REASON),
      "exactly one delivery must record #{DUPLICATE_REASON.inspect}; got #{errors.inspect}"
    assert_equal 1, errors.count(nil),
      "exactly one delivery must have emitted and cleared the error; got #{errors.inspect}"
  end

  test "neither delivery raises, so the endpoint answers 200 twice" do
    records = deliver_twice_at_once

    assert_equal 2, records.size
    records.each { |record| assert_predicate record, :persisted? }
  end

  test "two simultaneous deliveries of one event id are recorded once" do
    deliver_twice_at_once

    assert_equal 1, delivery_rows
  end

  test "a validation failure that is not a uniqueness race is still parked for a human" do
    record = Customer.new(processor: "stripe", processor_customer_id: "cus_control")

    error = assert_raises(ActiveRecord::RecordInvalid) { record.save! }

    refute ingestion_says_uniqueness_race?(error),
      "a plain validation failure was read as the duplicate a constraint already " \
      "recorded. Widening this predicate files a bug in this service as a race and " \
      "answers the processor 200."
  end

  test "the predicate recognises a uniqueness failure as a duplicate" do
    owner = SecureRandom.uuid
    Customer.create!(owner_type: "User", owner_id: owner,
      processor: "stripe", processor_customer_id: "cus_dup_control")
    duplicate = Customer.new(owner_type: "User", owner_id: owner,
      processor: "stripe", processor_customer_id: "cus_dup_control")

    error = assert_raises(ActiveRecord::RecordInvalid) { ActiveRecord::Base.uncached { duplicate.save! } }

    assert ingestion_says_uniqueness_race?(error),
      "a real uniqueness failure was not recognised, so a losing delivery would be " \
      "parked as a failure for an event that is already published"
  end


  test "two simultaneous creations of one subscription produce one subscription and one start" do
    body, = subscription_fixture_rows

    records = deliver_concurrently(body, event_id: "evt_1PZQaBcDeFgHiJkLmNoPqR5")

    assert_equal 1, subscription_rows,
      "#{subscription_rows} subscription rows for one processor subscription id. The " \
      "outbox index cannot catch this one: a start payload carries no processor_event_id."
    assert_equal 1, started_events,
      "billing.subscription.started was published twice; a consumer counting " \
      "signups would count every signup twice"
    refute records.any?(&:failed?),
      "the losing creation was parked as a failure: #{records.map(&:error).inspect}"
  end

  test "a start payload carries no processor_event_id, so the subscriptions table refuses the duplicate" do
    body, = subscription_fixture_rows

    Webhooks::Ingestion.new(
      processor: :stripe, event_id: "evt_started_shape",
      type: body["type"], payload: body.merge("id" => "evt_started_shape")
    ).call

    start = OutboxEvent.find_by(event_type: "billing.subscription.started")
    refute start.data.key?("processor_event_id"),
      "if the start payload carried the key, this file's other half would be " \
      "testing the outbox index and the subscriptions index would be untested"
  end


  test "two simultaneous deliveries of two different event ids emit two events" do
    deliver_twice_at_once(event_ids: [ "evt_race_a", "evt_race_b" ])

    assert_equal 2, outbox_rows
    assert_equal %w[evt_race_a evt_race_b],
      ActiveRecord::Base.uncached {
        OutboxEvent.order(:created_at, :id).pluck(:data).map { |data| data.fetch("processor_event_id") }.sort
      }
  end

  test "two simultaneous deliveries of two different event ids are both handled" do
    records = deliver_twice_at_once(event_ids: [ "evt_race_a", "evt_race_b" ])

    refute_includes records.map(&:error), DUPLICATE_REASON,
      "two different event ids are two events; neither may be recorded as a duplicate"
    records.each { |record| assert_nil record.error, "a delivery that emitted carries no error" }
  end

  private
    def ingestion_says_uniqueness_race?(error)
      Webhooks::Ingestion.allocate.send(:uniqueness_race?, error)
    end

    def outbox_rows
      ActiveRecord::Base.uncached { OutboxEvent.count }
    end

    def delivery_rows
      ActiveRecord::Base.uncached { ProcessorWebhook.count }
    end

    def subscription_rows
      ActiveRecord::Base.uncached { Subscription.count }
    end

    def started_events
      ActiveRecord::Base.uncached { OutboxEvent.where(event_type: "billing.subscription.started").count }
    end

    def deliver_twice_at_once(event_ids: [ INVOICE_PAID_PAYLOAD_ID, INVOICE_PAID_PAYLOAD_ID ])
      body = JSON.parse(stripe_fixture(INVOICE_PAID))

      holding_the_gate_open(BothArrived.new) do
        records = event_ids.map { |event_id| Thread.new { ingest_body(body, event_id) } }.map(&:value)
        forget_what_was_counted_before_the_threads_ran
        records
      end
    end

    INVOICE_PAID_PAYLOAD_ID = "evt_1PZQaBcDeFgHiJkLmNoPqR4".freeze

    def ingest(event_id)
      ingest_body(JSON.parse(stripe_fixture(INVOICE_PAID)), event_id)
    end

    def subscription_fixture_rows
      body = JSON.parse(stripe_fixture("customer.subscription.created"))
      object = body.dig("data", "object")

      create_stripe_customer(processor_customer_id: object["customer"])
      create_stripe_plan(processor_price_id: object.dig("items", "data", 0, "price", "id"))

      [ body, object ]
    end

    def ingest_body(body, event_id)
      body = body.merge("id" => event_id, "type" => body["type"])
      Webhooks::Ingestion.new(
        processor: :stripe, event_id: event_id, type: body["type"], payload: body
      ).call
    end

    def deliver_concurrently(body, event_id:)
      barrier = BothArrived.new

      holding_the_gate_open(barrier) do
        records = 2.times.map { Thread.new { ingest_body(body, event_id) } }.map(&:value)
        forget_what_was_counted_before_the_threads_ran
        records
      end
    end

    def forget_what_was_counted_before_the_threads_ran
      ActiveRecord::Base.connection.clear_query_cache
    end

    def holding_the_gate_open(barrier)
      ProcessorWebhook.class_eval do
        alias_method :ungated_handled?, :handled?
        define_method(:handled?) do
          barrier.wait_for_the_other
          ungated_handled?
        end
      end

      yield
    ensure
      ProcessorWebhook.class_eval do
        alias_method :handled?, :ungated_handled?
        remove_method :ungated_handled?
      end
    end

    def clear_written_tables
      Subscription.delete_all
      ProcessorWebhook.delete_all
      OutboxEvent.delete_all
      Plan.delete_all
      Customer.delete_all
    end

    class BothArrived
      def initialize
        @mutex = Mutex.new
        @open = ConditionVariable.new
        @arrived = 0
      end

      def wait_for_the_other
        @mutex.synchronize do
          @arrived += 1
          @open.broadcast
          @open.wait(@mutex) while @arrived < 2
        end
      end
    end
end
