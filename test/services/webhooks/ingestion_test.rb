require "test_helper"

class Webhooks::IngestionTest < ActiveSupport::TestCase
  INVOICE_PAID = "invoice.paid".freeze
  SUBSCRIPTION_CREATED = "customer.subscription.created".freeze

  setup do
    travel_to(frozen_now)
  end

  def ingest(fixture, payload: nil, event_id: nil, type: nil)
    body = payload || JSON.parse(stripe_fixture(fixture))
    body = body.merge("id" => event_id) if event_id

    Webhooks::Ingestion.new(
      processor: :stripe,
      event_id: event_id || body["id"],
      type: type || body["type"],
      payload: body
    ).call
  end

  test "a handled event is stored, processed, and emits one internal event" do
    record = ingest(INVOICE_PAID)

    assert_predicate record, :persisted?
    assert_predicate record.processed_at, :present?
    assert_nil record.error
    assert_equal "stripe", record.processor
    assert_equal "evt_1PZQaBcDeFgHiJkLmNoPqR4", record.stripe_event_id
    assert_equal 1, OutboxEvent.count
  end

  test "the stored payload is the body verbatim, with the processor's own keys" do
    record = ingest(INVOICE_PAID)

    assert_equal JSON.parse(stripe_fixture(INVOICE_PAID)), record.payload
  end

  test "the row is keyed on the processor's own event id, not one this service invented" do
    record = ingest(INVOICE_PAID)

    assert_equal JSON.parse(stripe_fixture(INVOICE_PAID)).fetch("id"), record.stripe_event_id
  end

  test "replaying the same event id processes once" do
    first = ingest(INVOICE_PAID)
    second = ingest(INVOICE_PAID)

    assert_equal first.id, second.id
    assert_equal 1, ProcessorWebhook.count
    assert_equal 1, OutboxEvent.count
  end

  test "replaying a processed event does not re-emit" do
    ingest(INVOICE_PAID)
    ingest(INVOICE_PAID)

    assert_equal 1, OutboxEvent.where(event_type: "billing.payment.succeeded").count
  end

  test "a late redelivery of the same event id emits no second event" do
    ingest(INVOICE_PAID)
    travel_to 20.minutes.from_now do
      ingest(INVOICE_PAID)
    end

    assert_equal 1, OutboxEvent.count
  end

  test "two different event ids of the same type are two events" do
    ingest(INVOICE_PAID, event_id: "evt_a")
    ingest(INVOICE_PAID, event_id: "evt_b")

    assert_equal 2, ProcessorWebhook.count
    assert_equal 2, OutboxEvent.count
  end

  test "each emitted event carries the id of the delivery it came from" do
    ingest(INVOICE_PAID, event_id: "evt_a")
    ingest(INVOICE_PAID, event_id: "evt_b")

    assert_equal %w[evt_a evt_b],
      OutboxEvent.order(:created_at, :id).pluck(:data).map { |data| data.fetch("processor_event_id") }.sort
  end

  test "an event with no handler is stored and marked processed as ignored" do
    record = ingest("charge.succeeded")

    assert_predicate record, :persisted?
    assert_predicate record.processed_at, :present?
    assert_equal "ignored:unhandled_event_type", record.error
    assert_equal 0, OutboxEvent.count
  end

  test "a deliberately ignored type records the reason it was ignored" do
    record = ingest("ping")

    assert_predicate record.processed_at, :present?
    assert_equal "ignored:connectivity_check", record.error
    assert_equal 0, OutboxEvent.count
  end

  test "ignoring is not a retry: the second ping is not processed again" do
    ingest("ping")
    ingest("ping")

    assert_equal 1, ProcessorWebhook.count
  end

  test "a handler that raises records the failure instead of propagating it" do
    exploding = Class.new do
      def self.call(*) = raise(ArgumentError, "deliberate test failure")
    end

    with_handler(INVOICE_PAID, exploding) do
      record = ingest(INVOICE_PAID)

      assert_predicate record.processed_at, :present?
      assert_equal "failed:ArgumentError: deliberate test failure", record.error
      assert_equal 0, OutboxEvent.count
    end
  end

  test "a failure is not retried as new work" do
    exploding = Class.new do
      def self.call(*) = raise(ArgumentError, "deliberate test failure")
    end

    with_handler(INVOICE_PAID, exploding) do
      ingest(INVOICE_PAID)
      ingest(INVOICE_PAID)
    end

    assert_equal 1, ProcessorWebhook.count
  end

  test "a rejected payload shape is recorded as a failure, not a 500" do
    record = ingest(INVOICE_PAID, payload: { "id" => "evt_1", "type" => "invoice.paid" })

    assert_predicate record.processed_at, :present?
    assert record.error.start_with?("failed:"), "expected a recorded failure, got: #{record.error.inspect}"
    assert_equal 0, OutboxEvent.count
  end

  test "a failure records the processor event id so the failing row is findable" do
    exploding = Class.new do
      def self.call(*) = raise(ArgumentError, "deliberate test failure")
    end

    record = with_handler_result(INVOICE_PAID, exploding) do
      ingest(INVOICE_PAID, event_id: "evt_findable")
    end

    found = ProcessorWebhook.find_by(stripe_event_id: "evt_findable")

    assert_equal record.id, found.id
    assert_predicate found.error, :present?
  end

  test "a marking that cannot be written leaves no event behind it" do
    with_refused_marking do
      assert_raises(ActiveRecord::StatementInvalid) { ingest(INVOICE_PAID) }
    end

    assert_equal 0, OutboxEvent.count
  end

  test "a marking that cannot be written leaves the row visibly unfinished" do
    with_refused_marking do
      assert_raises(ActiveRecord::StatementInvalid) { ingest(INVOICE_PAID) }
    end

    stored = ProcessorWebhook.sole

    assert_nil stored.processed_at
    assert_nil stored.error
  end

  test "a redelivery of an event whose marking never landed is processed again" do
    with_refused_marking do
      assert_raises(ActiveRecord::StatementInvalid) { ingest(INVOICE_PAID) }
    end

    record = ingest(INVOICE_PAID)

    assert_equal 1, ProcessorWebhook.count
    assert_predicate record.processed_at, :present?
    assert_equal 1, OutboxEvent.count
    assert_equal "billing.payment.succeeded", OutboxEvent.sole.event_type
  end

  test "a subscription-mode checkout session is recorded as ignored, not as a failure" do
    record = ingest("checkout.session.completed")

    assert_predicate record.processed_at, :present?
    assert_equal "ignored:subscription_mode_is_restated_by_the_subscription_lifecycle", record.error
    assert_equal 0, OutboxEvent.count
  end

  test "a subscription-mode checkout session is not retried as new work" do
    ingest("checkout.session.completed")
    ingest("checkout.session.completed")

    assert_equal 1, ProcessorWebhook.count
  end

  test "a subscription signup states one fact once, not once per delivery channel" do
    create_stripe_customer
    create_stripe_plan

    ingest("checkout.session.completed")
    ingest("customer.subscription.created")

    assert_equal [ "billing.subscription.started" ],
      OutboxEvent.where(event_type: "billing.subscription.started").pluck(:event_type)
  end

  test "a handler is given the payload and the time the change happened" do
    seen = []
    handler = ->(payload, event_time) do
      seen << [ payload.fetch("id"), event_time ]
      Webhooks::Emission.new(event_type: "billing.payment.succeeded", subject: "cus_1", data: {})
    end

    with_handler(INVOICE_PAID, handler) { ingest(INVOICE_PAID) }

    created = JSON.parse(stripe_fixture(INVOICE_PAID)).fetch("created")
    assert_equal [ [ "evt_1PZQaBcDeFgHiJkLmNoPqR4", Time.at(created).utc ] ], seen
  end

  test "the subject is the processor's subscription id when the payload has one" do
    ingest(INVOICE_PAID)

    assert_equal "sub_1PZQaBcDeFgHiJkLmNoPqR1", OutboxEvent.sole.subject
  end

  test "the subject falls back to the customer id when there is no subscription" do
    ingest("checkout.session.completed.payment")

    assert_equal "cus_R1pQKz9xLp2mN4vB6yH8jL0", OutboxEvent.sole.subject
  end

  test "ingestion stamps the event's own time, not the time it was received" do
    travel_to 3.days.from_now do
      ingest(INVOICE_PAID)
    end

    assert_equal Time.utc(2026, 10, 7, 4, 0, 0), OutboxEvent.sole.time
  end

  test "an event with no processor timestamp falls back to the time it was received" do
    payload = JSON.parse(stripe_fixture(INVOICE_PAID))
    payload.delete("created")

    ingest(INVOICE_PAID, payload: payload)

    assert_equal frozen_now, OutboxEvent.sole.time
  end

  test "a mapping to an event type the outbox does not list parks the row" do
    unlisted = Webhooks::Emission.new(event_type: "billing.payment.on_settled", subject: "pi_1", data: {})

    with_handler(INVOICE_PAID, ->(_payload, _event_time) { unlisted }) do
      record = ingest(INVOICE_PAID)

      assert record.error.start_with?("failed:ActiveRecord::RecordInvalid:"),
        "expected a parked row, got: #{record.error.inspect}"
      assert_predicate record.processed_at, :present?
      assert_equal 0, OutboxEvent.count
    end
  end

  test "a uniqueness failure from the handler is a duplicate delivery, not a row for a human" do
    taken = Subscription.new
    taken.errors.add(:processor_subscription_id, :taken)

    with_handler(SUBSCRIPTION_CREATED, ->(_payload, _event_time) { raise ActiveRecord::RecordInvalid, taken }) do
      record = ingest(SUBSCRIPTION_CREATED)

      assert_equal "ignored:duplicate_delivery", record.error
      assert_predicate record, :ignored?
      refute_predicate record, :failed?
      assert_predicate record.processed_at, :present?
      assert_equal 0, ActiveRecord::Base.uncached { OutboxEvent.count }
    end
  end

  test "a unique violation that is not this event's own fact is parked, not called a duplicate" do
    with_handler(SUBSCRIPTION_CREATED, lambda { |_payload, _event_time|
      raise ActiveRecord::RecordNotUnique, 'duplicate key value violates unique constraint "subscriptions_live_account_plan_idx"'
    }) do
      record = ingest(SUBSCRIPTION_CREATED)

      assert record.error.start_with?("failed:ActiveRecord::RecordNotUnique:"),
        "a refusal that duplicates nothing must not be answered as a decision; got: #{record.error.inspect}"
      refute_predicate record, :ignored?
      assert_predicate record.processed_at, :present?
    end
  end

  test "a validation failure that is not a uniqueness failure is still parked" do
    broken = Subscription.new
    broken.errors.add(:status, :inclusion, message: "is not included")

    with_handler(SUBSCRIPTION_CREATED, ->(_payload, _event_time) { raise ActiveRecord::RecordInvalid, broken }) do
      record = ingest(SUBSCRIPTION_CREATED)

      assert record.error.start_with?("failed:ActiveRecord::RecordInvalid:"),
        "a non-uniqueness validation failure is a bug and belongs in front of a human; got: #{record.error.inspect}"
    end
  end

  test "a processor this service does not speak is refused at the edge" do
    assert_raises(ArgumentError) do
      Webhooks::Ingestion.new(processor: :adyen, event_id: "evt_1", type: "ping", payload: {}).call
    end
  end

  test "an event with no type is refused at the edge" do
    assert_raises(ArgumentError) do
      Webhooks::Ingestion.new(processor: :stripe, event_id: "evt_1", type: nil, payload: {}).call
    end
  end

  test "an event with no processor event id is refused at the edge" do
    assert_raises(ArgumentError) do
      Webhooks::Ingestion.new(processor: :stripe, event_id: nil, type: "ping", payload: {}).call
    end
  end

  private
    REFUSE_TO_MARK = ->(_record) { raise ActiveRecord::StatementInvalid, "connection lost while writing" }

    def with_refused_marking
      ProcessorWebhook.set_callback(:update, :before, REFUSE_TO_MARK)
      yield
    ensure
      ProcessorWebhook.skip_callback(:update, :before, REFUSE_TO_MARK)
    end

    def with_handler(type, handler)
      real = Webhooks::StripeEvents.method(:handler_for)
      simple_stubs.stub_object(Webhooks::StripeEvents, :handler_for) do |given|
        given == type ? handler : real.call(given)
      end
      yield
    ensure
      simple_stubs.unstub_all!
    end

    def with_handler_result(type, handler)
      result = nil
      with_handler(type, handler) { result = yield }
      result
    end
end
