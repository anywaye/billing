require "test_helper"

class SubscriptionDeliveryTest < ActiveSupport::TestCase
  SEQUENCE = %w[
    customer.subscription.created
    customer.subscription.updated
    customer.subscription.deleted
  ].freeze

  SUBSCRIPTION_EVENTS = %w[
    billing.subscription.started
    billing.subscription.updated
    billing.subscription.canceled
  ].freeze

  COURIER_LISTENS_FOR = %w[
    billing.subscription.started
    billing.subscription.canceled
  ].freeze

  setup do
    travel_to(frozen_now)
    @customer = create_stripe_customer
    @plan = create_stripe_plan
  end

  test "the sweep covers every event the lifecycle acts on" do
    assert_equal Subscriptions::Lifecycle::TYPES.sort, SEQUENCE.sort
  end

  test "this file's list of published events is the lifecycle's" do
    published = Subscriptions::Lifecycle.constants
      .grep(/\A(STARTED|UPDATED|CANCELED)_EVENT\z/)
      .map { |name| Subscriptions::Lifecycle.const_get(name) }

    assert_equal SUBSCRIPTION_EVENTS.sort, published.sort
  end

  SEQUENCE.each_with_index do |fixture, index|
    test "delivering #{fixture} twice, in its real context, changes nothing" do
      SEQUENCE.first(index).each { |earlier| deliver(earlier) }

      deliver(fixture)
      subscription = Subscription.sole.attributes
      events = subscription_events
      delivery = ProcessorWebhook.find_by(stripe_event_id: event_id(fixture)).attributes

      deliver(fixture)

      assert_equal subscription, Subscription.sole.attributes
      assert_equal events, subscription_events
      assert_equal delivery, ProcessorWebhook.find_by(stripe_event_id: event_id(fixture)).attributes
    end

    test "delivering #{fixture} twice leaves one delivery row for it" do
      SEQUENCE.first(index).each { |earlier| deliver(earlier) }
      2.times { deliver(fixture) }

      assert_equal 1, ProcessorWebhook.where(stripe_event_id: event_id(fixture)).count
    end
  end

  test "the whole lifecycle delivers twice end to end and emits three events" do
    2.times { SEQUENCE.each { |fixture| deliver(fixture) } }

    assert_equal 3, ProcessorWebhook.count
    assert_equal [ "billing.subscription.started", "billing.subscription.updated", "billing.subscription.canceled" ],
      subscription_event_types
  end

  test "a fresh event id reporting the state we already hold emits nothing" do
    deliver("customer.subscription.created")
    before = subscription_events

    record = deliver("customer.subscription.created", event_id: "evt_the_same_fact_under_a_new_id")

    assert_equal before, subscription_events
    assert_equal "ignored:no_change_to_record", record.error
  end

  test "a fresh event id reporting the state we already hold changes no column" do
    deliver("customer.subscription.created")
    before = Subscription.sole.attributes

    deliver("customer.subscription.created", event_id: "evt_the_same_fact_under_a_new_id")

    assert_equal before, Subscription.sole.attributes
  end

  test "a genuinely different fact under a fresh id is published, not suppressed" do
    deliver("customer.subscription.created")
    before = subscription_event_types

    deliver("customer.subscription.updated", event_id: "evt_a_really_different_fact")

    assert_equal before + [ "billing.subscription.updated" ], subscription_event_types
  end


  test "a signup publishes the event courier delivers the welcome mail from" do
    deliver("customer.subscription.created")

    assert_equal COURIER_LISTENS_FOR.first, subscription_event_types.sole
  end

  test "a cancellation publishes the event courier delivers the confirmation from" do
    deliver("customer.subscription.created")
    deliver("customer.subscription.deleted")

    assert_equal COURIER_LISTENS_FOR.last, subscription_event_types.last
  end

  test "both events courier needs are declared in the manifest" do
    manifest = YAML.load_file(Rails.root.join("anywaye.yml"))

    assert_empty COURIER_LISTENS_FOR - manifest.dig("exposes", "events")
  end

  test "both events courier needs are in the outbox's closed list" do
    assert_empty COURIER_LISTENS_FOR - OutboxEvent::TYPES
  end

  test "both events courier needs have a row in core's catalog" do
    core_catalog = TestSupport::CoreLocation.path_for.join("docs", "event-naming.md")
    catalog = begin
      File.read(core_catalog)
    rescue Errno::ENOENT, Errno::ENOTDIR
      skip("core is not on disk at #{core_catalog}; set CORE_PATH to a core checkout")
    end
    billing_section = catalog[/^### billing.*?(?=^### |\z)/m].to_s

    COURIER_LISTENS_FOR.each do |event_type|
      assert_includes billing_section, "`#{event_type}`",
        "core's catalog has no row for #{event_type}, so nothing downstream could subscribe to it"
    end
  end

  test "billing consumes no events, so it is not waiting on courier to do anything" do
    manifest = YAML.load_file(Rails.root.join("anywaye.yml"))

    assert_equal [], manifest.fetch("consumes")
  end

  test "the welcome-mail event and the subscription commit together" do
    with_refused_emission { deliver("customer.subscription.created") }

    assert_equal 0, Subscription.count
    assert_equal [], subscription_event_types
  end

  test "the confirmation event and the cancellation commit together" do
    deliver("customer.subscription.created")

    with_refused_emission { deliver("customer.subscription.deleted") }

    assert_equal "active", Subscription.sole.status
    assert_equal [ "billing.subscription.started" ], subscription_event_types
  end

  private
    def subscription_events
      OutboxEvent.where(event_type: SUBSCRIPTION_EVENTS).order(:created_at, :id).map(&:attributes)
    end

    def subscription_event_types
      OutboxEvent.where(event_type: SUBSCRIPTION_EVENTS).order(:created_at, :id).pluck(:event_type)
    end

    def event_id(fixture)
      JSON.parse(stripe_fixture(fixture)).fetch("id")
    end

    def deliver(fixture, event_id: nil)
      body = JSON.parse(stripe_fixture(fixture))
      resolved_id = event_id || body["id"]
      body = body.merge("id" => resolved_id)

      travel_to(frozen_now + (@deliveries = @deliveries.to_i + 1)) do
        Webhooks::Ingestion.new(
          processor: :stripe,
          event_id: resolved_id,
          type: body["type"],
          payload: body
        ).call
      end
    end

    REFUSE_TO_EMIT = ->(_event) { raise ActiveRecord::StatementInvalid, "delivery lost while emitting" }

    def with_refused_emission
      OutboxEvent.set_callback(:create, :before, REFUSE_TO_EMIT)
      yield
    ensure
      OutboxEvent.skip_callback(:create, :before, REFUSE_TO_EMIT)
    end
end
