require "test_helper"

class StripeClientLiveTest < ActiveSupport::TestCase
  PRICE_A = "price_1UQwacCmN780pAiWr0mwVOHB".freeze
  PRICE_B = "price_1UQwaeCmN780pAiWzC9ZFriq".freeze
  CUSTOMER = "cus_VRqHdzgTgwLPA1".freeze
  SUBSCRIPTION_CANCEL = "sub_1UQwgHCmN780pAiWxvYd5PVm".freeze
  SUBSCRIPTION_CHANGE = "sub_1UQwgMCmN780pAiWWD4CT9r5".freeze
  SUBSCRIPTION_INVOICE = "sub_1UQwgQCmN780pAiWTjQDKffS".freeze

  def client
    @client ||= Processor::StripeClient.new(
      api_key: ENV["STRIPE_API_KEY"] || "sk_test_replayed_from_cassette"
    )
  end

  test "a real Checkout session comes back with the processor's own URL" do
    VCR.use_cassette("stripe/create_checkout_session") do
      session = client.create_checkout_session(
        plan_price_id: PRICE_A,
        customer_reference: "11111111-1111-4111-8111-111111111111",
        success_url: "https://app.anywaye.com/billing",
        processor_customer_id: CUSTOMER
      )

      assert session.id.start_with?("cs_test_"), "Stripe minted #{session.id.inspect}"
      assert session.url.start_with?("https://checkout.stripe.com/c/pay/cs_test_"),
        "the URL is the processor's own: #{session.url.inspect}"
      assert_equal "subscription", session.mode
      assert_equal 1900, session.amount_total
      assert_equal "usd", session.currency
      assert_equal CUSTOMER, session.customer
      assert_equal "11111111-1111-4111-8111-111111111111", session.client_reference_id
    end
  end

  test "a real plan change moves the subscription's price" do
    VCR.use_cassette("stripe/apply_plan_change") do
      updated = client.apply_plan_change(
        processor_subscription_id: SUBSCRIPTION_CHANGE,
        price_id: PRICE_B,
        proration_behavior: "none"
      )

      assert_equal SUBSCRIPTION_CHANGE, updated.id
      assert_equal PRICE_B, updated.items.data.first.price.id
      assert_equal "active", updated.status
    end
  end

  test "a real cancellation sets cancel_at_period_end and keeps the subscription live" do
    VCR.use_cassette("stripe/cancel_subscription") do
      canceled = client.cancel_subscription(
        processor_subscription_id: SUBSCRIPTION_CANCEL,
        at_period_end: true
      )

      assert_equal true, canceled.cancel_at_period_end
      refute_equal "canceled", canceled.status
      assert_equal "active", canceled.status
    end
  end

  test "a real upcoming invoice names the period, the line and the totals" do
    VCR.use_cassette("stripe/upcoming_invoice") do
      invoice = client.upcoming_invoice(
        processor_subscription_id: SUBSCRIPTION_INVOICE,
        processor_customer_id: CUSTOMER
      )

      assert_equal "usd", invoice.currency
      assert_instance_of Integer, invoice.subtotal
      assert_operator invoice.subtotal, :>, 0
      line = invoice.lines.data.first
      assert_equal 1900, BigDecimal(line.pricing.unit_amount_decimal.to_s).to_i
      assert_respond_to invoice, :total_excluding_tax
    end
  end

  test "a real portal session comes back as a URL, or as the processor's own refusal" do
    VCR.use_cassette("stripe/billing_portal") do
      begin
        url = client.billing_portal_url(processor_customer_id: CUSTOMER, return_url: "https://app.anywaye.com/billing")
        assert url.is_a?(String) && url.start_with?("https://")
      rescue Processor::StripeClient::RequestFailed => refusal
        assert_match(/configuration|No such|billing portal/i, refusal.message)
      end
    end
  end
end
