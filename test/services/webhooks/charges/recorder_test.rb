require "test_helper"

# The recorder: the only thing that writes a `Charge`, and the rule it exists to
# hold is **a charge is recorded when money moved, and never when it did not.**
#
# Every case here is a payment event that either does or does not become a
# receipt, and the distinction is the processor's own `paid` and `amount` — never
# anything this service decided. The recorder is tested directly rather than
# through the webhook so each precondition is isolated: the webhook's own specs
# cover the signature, the storage and the at-most-once, and this file covers
# the write.
class Webhooks::Charges::RecorderTest < ActiveSupport::TestCase
  ACCOUNT_ID = "11111111-1111-4111-8111-111111111111"
  OTHER_ACCOUNT_ID = "22222222-2222-4222-8222-222222222222"

  # The processor customer id both payment fixtures carry. Obviously fake, like
  # every processor id in `test/support/two_accounts.rb`.
  CUSTOMER = "cus_R1pQKz9xLp2mN4vB6yH8jL0".freeze

  setup do
    travel_to(frozen_now)

    @customer = Customer.create!(
      owner_type: "Account", owner_id: ACCOUNT_ID, processor: "stripe",
      processor_customer_id: CUSTOMER
    )
  end

  # --- a payment that settled becomes a charge --------------------------------

  test "a paid invoice records a charge" do
    charge = record("invoice.paid")

    assert_kind_of Charge, charge
    assert_equal ACCOUNT_ID, charge.account_id
    assert_equal @customer.id, charge.customer_id
    assert_equal "ch_3PZQaBcDeFgHiJkLmNoPqR6", charge.processor_charge_id
    assert_equal 8_700, charge.amount
    assert_equal "USD", charge.currency
    assert_equal frozen_now, charge.paid_at
  end

  # The description is the invoice's line item — the answer to "what did I pay
  # for" — read off the raw payload because the normalized hash carries only
  # what the event publishes.
  test "a paid invoice's charge carries the line item as its description" do
    charge = record("invoice.paid")

    assert_equal "3 × Pro monthly", charge.description
  end

  # A one-time Checkout payment has no invoice and no subscription; the
  # payment intent is the processor's own unique id for it, which is what the
  # UNIQUE index dedupes a redelivery on.
  test "a one-time checkout payment records a charge keyed by the payment intent" do
    charge = record("checkout.session.completed.payment")

    assert_kind_of Charge, charge
    assert_equal "pi_3PZQaBcDeFgHiJkLmNoPqRd", charge.processor_charge_id
    assert_equal 1_500, charge.amount
    assert_nil charge.subscription_id
  end

  # The account is resolved from the customer the payment is for, because a
  # charge is billed to an account and the customer is the link back to it.
  test "a charge's account is the resolved customer's owner" do
    charge = record("invoice.paid")

    assert_equal @customer.owner_id, charge.account_id
  end

  # --- a payment that did not settle records nothing ---------------------------

  # The rule the whole object exists for. A failed payment is a fact about money
  # that did not move, and a receipt for it would be a claim a customer paid
  # when they did not.
  test "a failed invoice records no charge" do
    assert_no_difference "Charge.count" do
      record("invoice.payment_failed")
    end
  end

  # A zero-amount settlement — an invoice covered entirely by credit balance —
  # is `paid: true` but no money moved. The amount guard is what skips it.
  test "a paid invoice with a zero amount records no charge" do
    assert_no_difference "Charge.count" do
      record("invoice.paid", "amount_paid" => 0)
    end
  end

  # A negative settlement is the same case with a sign: Stripe reports a
  # credit-covered invoice as a negative `amount_paid`. `Billing::Money` permits a
  # negative amount and the CHECK constraint refuses the row, so recording it
  # would raise from inside a webhook and park a correct event.
  test "a paid invoice with a negative amount records no charge" do
    assert_no_difference "Charge.count" do
      record("invoice.paid", "amount_paid" => -1_900)
    end
  end

  # --- a payment this service cannot attribute records nothing -----------------

  # An `invoice.paid` for a customer created in the processor's dashboard has
  # no anywaye customer. The customer is required, so proceeding would raise
  # over a payment that was perfectly real — the skip is the decision.
  test "a payment for an unknown customer records no charge" do
    assert_no_difference "Charge.count" do
      record("invoice.paid", "customer" => "cus_FAKEunknownAAAAAAAAAAAAA")
    end
  end

  # A `User`-owned customer is in no account and is therefore invisible to
  # `/v1`; a receipt nobody can read is not written.
  test "a payment for a user-owned customer records no charge" do
    user_customer = Customer.create!(
      owner_type: "User", owner_id: ACCOUNT_ID, processor: "stripe",
      processor_customer_id: "cus_FAKErecorderBBBBBBBBBBBBB"
    )

    assert_no_difference "Charge.count" do
      record("invoice.paid", "customer" => user_customer.processor_customer_id)
    end
  end

  # --- the subscription is the most trustworthy account answer -----------------

  # When the payment names a subscription, its `account_id` wins over the
  # customer's owner: the lifecycle verified it at the moment it wrote the row
  # and guards it against reassignment.
  test "a charge for a subscription takes the subscription's account" do
    other_customer = Customer.create!(
      owner_type: "Account", owner_id: OTHER_ACCOUNT_ID, processor: "stripe",
      processor_customer_id: "cus_FAKErecorderCCCCCCCCCCCCC"
    )
    subscription = Subscription.create!(
      account_id: OTHER_ACCOUNT_ID, customer: other_customer, plan: shared_plan,
      processor_subscription_id: "sub_FAKErecorderAAAAAAAAAAAAA", status: "active"
    )

    charge = record("invoice.paid", "subscription" => subscription.processor_subscription_id)

    assert_equal OTHER_ACCOUNT_ID, charge.account_id
    assert_equal subscription.id, charge.subscription_id
  end

  # --- a redelivery is the UNIQUE index's problem, not the recorder's ----------

  # The recorder is called once per delivery; the second delivery of one event
  # id is refused by `charges_processor_charge_id_idx` before this object is
  # reached. What is asserted here is that the recorder itself does not invent a
  # second opinion — it writes, and the constraint is what makes the write
  # idempotent.
  test "recording the same processor charge twice is refused by the uniqueness rule" do
    record("invoice.paid")

    assert_raises(ActiveRecord::RecordInvalid) do
      record("invoice.paid")
    end
  end

  private
    # Builds the normalized data and raw payload for a fixture, with optional
    # overrides applied to the event object, and runs the recorder.
    def record(fixture, overrides = {})
      payload = JSON.parse(stripe_fixture(fixture))
      data = Webhooks::StripeEvents.normalize(payload)

      overrides.each do |key, value|
        payload.dig("data", "object")[key] = value
        data = Webhooks::StripeEvents.normalize(payload)
      end

      Webhooks::Charges::Recorder.new(data: data, payload: payload, event_time: frozen_now).record
    end

    def shared_plan
      @shared_plan ||= Plan.create!(
        name: "Recorder plan", slug: "recorder-plan-#{SecureRandom.hex(6)}",
        price: Billing::Money.new(1_900, "USD"), interval: "month",
        processor_price_id: "price_FAKErecorderAAAAAAAAAAAAA"
      )
    end
end
