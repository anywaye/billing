require "test_helper"

class Webhooks::Charges::RecorderTest < ActiveSupport::TestCase
  ACCOUNT_ID = "11111111-1111-4111-8111-111111111111"
  OTHER_ACCOUNT_ID = "22222222-2222-4222-8222-222222222222"

  CUSTOMER = "cus_R1pQKz9xLp2mN4vB6yH8jL0".freeze

  setup do
    travel_to(frozen_now)

    @customer = Customer.create!(
      owner_type: "Account", owner_id: ACCOUNT_ID, processor: "stripe",
      processor_customer_id: CUSTOMER
    )
  end


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

  test "a paid invoice's charge carries the line item as its description" do
    charge = record("invoice.paid")

    assert_equal "3 × Pro monthly", charge.description
  end

  test "a one-time checkout payment records a charge keyed by the payment intent" do
    charge = record("checkout.session.completed.payment")

    assert_kind_of Charge, charge
    assert_equal "pi_3PZQaBcDeFgHiJkLmNoPqRd", charge.processor_charge_id
    assert_equal 1_500, charge.amount
    assert_nil charge.subscription_id
  end

  test "a charge's account is the resolved customer's owner" do
    charge = record("invoice.paid")

    assert_equal @customer.owner_id, charge.account_id
  end


  test "a failed invoice records no charge" do
    assert_no_difference "Charge.count" do
      record("invoice.payment_failed")
    end
  end

  test "a paid invoice with a zero amount records no charge" do
    assert_no_difference "Charge.count" do
      record("invoice.paid", "amount_paid" => 0)
    end
  end

  test "a paid invoice with a negative amount records no charge" do
    assert_no_difference "Charge.count" do
      record("invoice.paid", "amount_paid" => -1_900)
    end
  end


  test "a payment for an unknown customer records no charge" do
    assert_no_difference "Charge.count" do
      record("invoice.paid", "customer" => "cus_FAKEunknownAAAAAAAAAAAAA")
    end
  end

  test "a payment for a user-owned customer records no charge" do
    user_customer = Customer.create!(
      owner_type: "User", owner_id: ACCOUNT_ID, processor: "stripe",
      processor_customer_id: "cus_FAKErecorderBBBBBBBBBBBBB"
    )

    assert_no_difference "Charge.count" do
      record("invoice.paid", "customer" => user_customer.processor_customer_id)
    end
  end


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


  test "recording the same processor charge twice is refused by the uniqueness rule" do
    record("invoice.paid")

    assert_raises(ActiveRecord::RecordInvalid) do
      record("invoice.paid")
    end
  end

  private
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
