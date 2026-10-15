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
      processor_customer_id: LIVE_CUSTOMER_PROCESSOR_ID, email: "billing-live-test@cafaye.com"
    )
    @plan = Plan.create!(
      name: "Live Drill", slug: "live-drill-#{SecureRandom.hex(4)}",
      price: Money.new(1_900, "USD"), interval: "month",
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
