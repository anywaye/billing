require "test_helper"

class LiveInvoiceShapeTest < ActiveSupport::TestCase
  LIVE_INVOICE_ID = "in_1UQwqJCmN780pAiWOOYdgsKY".freeze
  LIVE_SUBSCRIPTION_ID = "sub_1UQwqJCmN780pAiWtdwAw6yx".freeze
  LIVE_CUSTOMER_PROCESSOR_ID = "cus_VRqHdzgTgwLPA1".freeze

  setup do
    travel_to(frozen_now)
    @customer = Customer.create!(
      owner_type: "Account", owner_id: SecureRandom.uuid, processor: "stripe",
      processor_customer_id: LIVE_CUSTOMER_PROCESSOR_ID, email: "billing-live-test@anywaye.com"
    )
    @plan = Plan.create!(
      name: "Live Drill", slug: "live-drill-#{SecureRandom.hex(4)}",
      price: Billing::Money.new(1_900, "USD"), interval: "month",
      processor_price_id: "price_1UQwacCmN780pAiWr0mwVOHB"
    )
    @subscription = Subscription.create!(
      account_id: @customer.owner_id, customer: @customer, plan: @plan,
      processor_subscription_id: LIVE_SUBSCRIPTION_ID, status: "active"
    )
  end

  test "a live invoice.paid records the charge, with the invoice id as the processor's key" do
    result = ingest_live_invoice

    charge = Charge.sole
    assert_equal 1_900, charge.amount
    assert_equal "USD", charge.currency
    assert_equal @customer.id, charge.customer_id
    assert_equal @subscription.id, charge.subscription_id
    assert_equal LIVE_INVOICE_ID, charge.processor_charge_id
    assert_equal @customer.owner_id, charge.account_id
    assert_nil result.error
  end

  test "a live invoice.paid's payment event names the processor's subscription, not the customer" do
    ingest_live_invoice

    event = OutboxEvent.find_by(event_type: "billing.payment.succeeded")
    assert_equal LIVE_SUBSCRIPTION_ID, event.subject,
      "the subject fell back to the customer id, which is what the live payload did before the fix"
    assert_equal "billing.payment.succeeded", event.event_type
  end

  test "an invoice.paid that arrives before any subscription event still records the charge" do
    body = stripe_fixture("invoice.paid.live-first-checkout")
    anywaye_id = JSON.parse(body).dig("data", "object", "parent", "subscription_details", "metadata", "anywaye_customer_id")

    customer = Customer.create!(
      id: anywaye_id, owner_type: "Account", owner_id: SecureRandom.uuid, processor: "stripe",
      email: "first-checkout@anywaye.com"
    )
    assert_nil customer.processor_customer_id, "the case under test is a customer the processor's id cannot resolve"

    result = ingest(body)

    assert_nil result.error
    charge = Charge.sole
    assert_equal 1_900, charge.amount
    assert_equal "USD", charge.currency
    assert_equal customer.id, charge.customer_id
    assert_equal customer.owner_id, charge.account_id
    assert_nil charge.subscription_id, "no subscription row exists yet, and the receipt does not wait for one"
    assert_equal "in_1UQxoPCmN780pAiW8Kp4oks8", charge.processor_charge_id
  end

  test "the live recording and the old fixture both pass the paid screen" do
    Customer.create!(
      owner_type: "Account", owner_id: SecureRandom.uuid, processor: "stripe",
      processor_customer_id: StripeSubscriptionFixtures::PROCESSOR_CUSTOMER_ID
    )

    old = ingest(stripe_fixture("invoice.paid"))
    assert_equal 8_700, Charge.order(:created_at).last.amount
    assert_nil old.error

    ingest_live_invoice
    assert_equal [ 8_700, 1_900 ], Charge.order(:created_at).pluck(:amount)
  end

  private
    def ingest_live_invoice(result_expected: false)
      ingest(stripe_fixture("invoice.paid.live-2026-03"))
    end

    def ingest(body)
      payload = JSON.parse(body)
      Webhooks::Ingestion.new(processor: :stripe, event_id: payload["id"], type: payload["type"], payload: payload).call
    end
end
