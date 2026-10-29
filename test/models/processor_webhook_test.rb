require "test_helper"

class ProcessorWebhookTest < ActiveSupport::TestCase
  PAYLOAD = { "id" => "evt_1", "type" => "ping", "data" => { "object" => {} } }.freeze

  test "stores the processor, the processor event id, the type and the raw payload" do
    webhook = ProcessorWebhook.ingest(processor: :stripe, event_id: "evt_1", type: "ping", payload: PAYLOAD)

    assert_predicate webhook, :persisted?
    assert_equal "stripe", webhook.processor
    assert_equal "evt_1", webhook.stripe_event_id
    assert_equal "ping", webhook.type
    assert_equal PAYLOAD, webhook.payload
  end

  test "a stored event is not processed until something processes it" do
    webhook = ProcessorWebhook.ingest(processor: :stripe, event_id: "evt_1", type: "ping", payload: PAYLOAD)

    assert_nil webhook.processed_at
    assert_nil webhook.error
  end

  test "ingesting the same event id twice stores one row" do
    first = ProcessorWebhook.ingest(processor: :stripe, event_id: "evt_1", type: "ping", payload: PAYLOAD)
    second = ProcessorWebhook.ingest(processor: :stripe, event_id: "evt_1", type: "ping", payload: PAYLOAD)

    assert_equal first.id, second.id
    assert_equal 1, ProcessorWebhook.count
  end

  test "a replay of the same event id does not overwrite the stored payload" do
    ProcessorWebhook.ingest(processor: :stripe, event_id: "evt_1", type: "ping", payload: PAYLOAD)
    ProcessorWebhook.ingest(processor: :stripe, event_id: "evt_1", type: "ping", payload: PAYLOAD.merge("data" => { "object" => { "tampered" => true } }))

    assert_equal PAYLOAD, ProcessorWebhook.find_by!(stripe_event_id: "evt_1").payload
  end

  test "two different event ids are two rows" do
    ProcessorWebhook.ingest(processor: :stripe, event_id: "evt_1", type: "ping", payload: PAYLOAD)
    ProcessorWebhook.ingest(processor: :stripe, event_id: "evt_2", type: "ping", payload: PAYLOAD)

    assert_equal 2, ProcessorWebhook.count
  end

  test "a unique index conflict returns the row the winner stored" do
    stored = ProcessorWebhook.ingest(processor: :stripe, event_id: "evt_1", type: "ping", payload: PAYLOAD)

    with_unique_index_conflict do
      conflicted = ProcessorWebhook.ingest(processor: :stripe, event_id: "evt_1", type: "ping", payload: PAYLOAD)

      assert_equal stored.id, conflicted.id
    end

    assert_equal 1, ProcessorWebhook.count
  end

  test "a unique index conflict does not raise" do
    ProcessorWebhook.ingest(processor: :stripe, event_id: "evt_1", type: "ping", payload: PAYLOAD)

    with_unique_index_conflict do
      assert_nothing_raised do
        ProcessorWebhook.ingest(processor: :stripe, event_id: "evt_1", type: "ping", payload: PAYLOAD)
      end
    end
  end

  test "requires a processor, an event id and a type" do
    webhook = ProcessorWebhook.new(processor: nil, stripe_event_id: nil, type: nil)

    assert_not webhook.valid?
    assert_includes webhook.errors.attribute_names, :processor
    assert_includes webhook.errors.attribute_names, :stripe_event_id
    assert_includes webhook.errors.attribute_names, :type
  end

  test "refuses a processor this service does not speak" do
    webhook = ProcessorWebhook.new(processor: "adyen", stripe_event_id: "evt_1", type: "ping")

    assert_not webhook.valid?
  end

  test "the database refuses a processor the model would refuse" do
    ProcessorWebhook.create!(processor: :stripe, stripe_event_id: "evt_1", type: "ping", payload: PAYLOAD)
    rogue = ProcessorWebhook.new(processor: "adyen", stripe_event_id: "evt_2", type: "ping", payload: PAYLOAD)

    assert_raises(ActiveRecord::StatementInvalid) { rogue.save!(validate: false) }
  end

  test "the event id is unique across the table" do
    ProcessorWebhook.create!(processor: :stripe, stripe_event_id: "evt_1", type: "ping", payload: PAYLOAD)
    duplicate = ProcessorWebhook.new(processor: :stripe, stripe_event_id: "evt_1", type: "ping", payload: PAYLOAD)

    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "handled marks the row processed with no error" do
    webhook = ProcessorWebhook.ingest(processor: :stripe, event_id: "evt_1", type: "ping", payload: PAYLOAD)

    webhook.handled!

    assert_predicate webhook.processed_at, :present?
    assert_nil webhook.error
  end

  test "ignore records the reason, so a deliberate no-op is not a mystery" do
    webhook = ProcessorWebhook.ingest(processor: :stripe, event_id: "evt_1", type: "ping", payload: PAYLOAD)

    webhook.ignore!("unhandled_event_type")

    assert_predicate webhook.processed_at, :present?
    assert_equal "ignored:unhandled_event_type", webhook.error
  end

  test "fail records the class and the message of what broke" do
    webhook = ProcessorWebhook.ingest(processor: :stripe, event_id: "evt_1", type: "ping", payload: PAYLOAD)

    webhook.fail!(Billing::Money::InvalidAmountError.new("10.5 is not a whole number of minor units"))

    assert_predicate webhook.processed_at, :present?
    assert_equal "failed:Billing::Money::InvalidAmountError: 10.5 is not a whole number of minor units", webhook.error
  end

  test "a recorded failure is bounded, so a huge message cannot bloat the table" do
    webhook = ProcessorWebhook.ingest(processor: :stripe, event_id: "evt_1", type: "ping", payload: PAYLOAD)

    webhook.fail!(Billing::Money::InvalidAmountError.new("x" * 5_000))

    assert_operator webhook.error.length, :<=, ProcessorWebhook::MAX_ERROR_LENGTH
  end

  test "the recorded failure starts with the class even when the message is cut" do
    webhook = ProcessorWebhook.ingest(processor: :stripe, event_id: "evt_1", type: "ping", payload: PAYLOAD)

    webhook.fail!(Billing::Money::InvalidAmountError.new("y" * 5_000))

    assert webhook.error.start_with?("failed:Billing::Money::InvalidAmountError: ")
  end

  test "the processor's own type is not read as an STI discriminator" do
    webhook = ProcessorWebhook.ingest(processor: :stripe, event_id: "evt_1", type: "customer.subscription.updated", payload: PAYLOAD)

    assert_equal webhook.id, ProcessorWebhook.find(webhook.id).id
  end

  private
    def with_unique_index_conflict
      simple_stubs.stub_object(ProcessorWebhook, :find_or_create_by!) do |*|
        raise ActiveRecord::RecordNotUnique, "duplicate key value violates unique constraint"
      end
      yield
    ensure
      simple_stubs.unstub_all!
    end
end
