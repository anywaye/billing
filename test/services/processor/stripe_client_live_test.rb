require "test_helper"

# The five requests, against a RECORDING of the real Stripe API.
#
# Every other spec of this client injects `FakeStripeAPI` and asserts on the
# request this repository BUILT. That proves the argument building and proves
# nothing about whether Stripe accepts it — a double answers with whatever
# shape its author imagined. This spec is the other half: the cassettes under
# `test/cassettes/stripe/` are recordings of the real test-mode API answering
# these exact requests, so what is asserted below is Stripe's own answer —
# the session it minted, the subscription it moved, the invoice it projected.
#
# Recorded against test mode with the fixture objects created by the CLI on
# 2026-10-15 (`stripe products/prices/customers/subscriptions create`), then
# replayed hermetically: `test/support/vcr.rb` forbids the network whenever a
# cassette is not being replayed, so a run of this file opens no socket and
# needs no key.
class StripeClientLiveTest < ActiveSupport::TestCase
  # The test-mode objects the recording is about. Not secrets: the price ids
  # are public handles, the customer and subscription ids name test-mode rows
  # whose cassette carries them verbatim.
  PRICE_A = "price_1UQwacCmN780pAiWr0mwVOHB".freeze
  PRICE_B = "price_1UQwaeCmN780pAiWzC9ZFriq".freeze
  CUSTOMER = "cus_VRqHdzgTgwLPA1".freeze
  # **One subscription per mutating test, and the reason is a measurement.**
  # The first recording shared one subscription across three tests; the
  # recording run executes for real, so the cancel test set
  # `cancel_at_period_end` on the row and the change test moved it to B —
  # and the SECOND recording run then read a world the first run had
  # already changed (the change test failed moving B→B, and the preview
  # answered "No upcoming invoices for customer" because a subscription
  # marked to cancel has no renewal to preview). Separate fixtures make
  # re-recording idempotent, which is what a cassette has to be.
  SUBSCRIPTION_CANCEL = "sub_1UQwgHCmN780pAiWxvYd5PVm".freeze
  SUBSCRIPTION_CHANGE = "sub_1UQwgMCmN780pAiWWD4CT9r5".freeze
  SUBSCRIPTION_INVOICE = "sub_1UQwgQCmN780pAiWTjQDKffS".freeze

  # Recording uses the REAL test-mode key from the environment; replaying
  # uses a placeholder. The client only checks the key's PRESENCE before
  # sending, and VCR filters the real value out of the cassette — so a
  # recorded run is green on any machine and no key is ever in git.
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
      # Stripe does not include line items on a session unless expanded, so
      # the price assertion reads the TOTAL — which is the price's own amount,
      # and the figure the buyer will actually be asked for.
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
      # The property this service's whole cancellation design rests on: asking
      # at the period end does NOT cancel now, and the row stays live until
      # the deletion arrives.
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
      # The line's unit amount lives at `pricing.unit_amount_decimal` as a
      # decimal string in minor units — the shape the controller's builder
      # reads, and the shape the recording proved the old `price` accessor
      # is not.
      # The gem coerces the decimal string to a BigDecimal, so the assertion
      # is on the VALUE — 1900 minor units exactly. The controller parses the
      # same value with BigDecimal and refuses a fractional one; this is the
      # real answer it will read in production.
      line = invoice.lines.data.first
      assert_equal 1900, BigDecimal(line.pricing.unit_amount_decimal.to_s).to_i
      # The two figures the controller's display delta reads, present on a
      # real answer rather than assumed from a fixture.
      assert_respond_to invoice, :total_excluding_tax
    end
  end

  test "a real portal session comes back as a URL, or as the processor's own refusal" do
    VCR.use_cassette("stripe/billing_portal") do
      begin
        url = client.billing_portal_url(processor_customer_id: CUSTOMER, return_url: "https://app.anywaye.com/billing")
        assert url.is_a?(String) && url.start_with?("https://")
      rescue Processor::StripeClient::RequestFailed => refusal
        # A test-mode account with no Billing Portal configuration answers
        # with a 400 whose message names the missing configuration. That IS
        # the behavioural answer — the client translated a real refusal —
        # and it is recorded so this spec is honest either way.
        assert_match(/configuration|No such|billing portal/i, refusal.message)
      end
    end
  end
end
