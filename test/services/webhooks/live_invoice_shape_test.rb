require "test_helper"

# The invoice shape the LIVE API sends, which the committed hand-written
# fixtures did not have.
#
# The old fixture carries `"paid": true`, a top-level `subscription` and a
# `charge` id — the shape Stripe used when the fixtures were written. The
# file next to it (`invoice.paid.live-2026-03.json`) is a VERBATIM recording
# of a real test-mode `invoice.paid` captured during the live drill on
# 2026-10-15, and three of those fields had moved:
#
#   * no `paid` boolean — the invoice's `status` is `"paid"`;
#   * no top-level `subscription` — it is `parent.subscription_details`;
#   * no `charge` and no `payment_intent` anywhere on the object.
#
# Measured against the running service: with the old normalizer, a real
# payment published `billing.payment.succeeded` and **recorded no charge at
# all** — the screen read `paid` as nil — and its subject was the CUSTOMER id
# instead of the processor's subscription id. Both are asserted here so the
# live shape cannot regress into "the tests pass and nobody gets a receipt".
class LiveInvoiceShapeTest < ActiveSupport::TestCase
  # The ids the captured invoice names, from the recording.
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
    # Neither `charge` nor `payment_intent` is on a live invoice; the
    # invoice's own id is what identifies the payment.
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

  # The FIRST checkout's delivery order, measured on this stack (2026-10-16):
  # `invoice.paid` arrives before `customer.subscription.created`, and the
  # customer — created by the Checkout session at the processor — has no
  # `processor_customer_id` in this service yet. The only link is the metadata
  # the session set on the subscription. Before the recorder read it, the
  # receipt for a payment this real was silently not written: the walk showed
  # `charges` at zero with Stripe holding a paid 19.00 invoice.
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
    # The old fixture resolves its own customer, which the hand-written
    # fixture id names (`cus_R1pQKz9xLp2mN4vB6yH8jL0`) — a different row
    # from the live one above, because the two recordings are of two
    # different test-mode customers.
    Customer.create!(
      owner_type: "Account", owner_id: SecureRandom.uuid, processor: "stripe",
      processor_customer_id: StripeSubscriptionFixtures::PROCESSOR_CUSTOMER_ID
    )

    old = ingest(stripe_fixture("invoice.paid"))
    assert_equal 8_700, Charge.order(:created_at).last.amount
    assert_nil old.error

    # And the live one, whose `paid` boolean does not exist.
    ingest_live_invoice
    assert_equal [ 8_700, 1_900 ], Charge.order(:created_at).pluck(:amount)
  end

  private
    def ingest_live_invoice(result_expected: false)
      ingest(stripe_fixture("invoice.paid.live-2026-03"))
    end

    def ingest(body)
      payload = JSON.parse(body)
      # The delivery id and the body's id are one value — the invariant
      # `AGENTS.md` records for the helpers.
      Webhooks::Ingestion.new(processor: :stripe, event_id: payload["id"], type: payload["type"], payload: payload).call
    end
end
