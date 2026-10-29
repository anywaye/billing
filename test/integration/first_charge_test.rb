require "test_helper"

class FirstChargeTest < ActionDispatch::IntegrationTest
  ACCOUNT_ID = TestSupport::TestIdentity::Account
  OTHER_ACCOUNT_ID = "22222222-2222-4222-8222-222222222222".freeze

  setup do
    travel_to(frozen_now)

    @plan = Plan.create!(
      name: "Pro monthly", slug: "pro-monthly",
      price: Billing::Money.new(1_900, "USD"), interval: "month",
      trial_days: 0, active: true,
      processor_price_id: "price_1PZQaBcDeFgHiJkLmNoPqR2",
      entitlements: { "features" => [ "Everything" ], "limits" => { "projects" => 10 } }
    )
    @customer = Customer.create!(
      owner_type: "Account", owner_id: ACCOUNT_ID, processor: "stripe",
      processor_customer_id: "cus_R1pQKz9xLp2mN4vB6yH8jL0",
      email: "buyer@example.com"
    )
    Processor::FakeClient.reset!
    @api = FakeStripeAPI.new
    @previous_client = Processor::StripeClient.current
    Processor::StripeClient.current = Processor::StripeClient.new(api_key: "sk_test", api: @api)
  end

  teardown do
    Processor::StripeClient.current = @previous_client
  end

  test "a stranger signs up, buys, and can read what they were charged" do
    post "/v1/checkouts", params: { customer_id: @customer.id, plan_id: @plan.id }, as: :json
    assert_response :created, "the checkout door answered #{response.status}: #{response.body}"

    subscription = Subscription.sole
    assert_equal "active", subscription.status, "a completed checkout must grant the entitlements it was bought for"
    assert_equal @plan.id, subscription.plan_id
    assert_equal @customer.id, subscription.customer_id
    assert_equal ACCOUNT_ID, subscription.account_id
    assert subscription.grants_entitlements?

    assert_equal 1, Processor::FakeClient.subscriptions.count
    assert_equal Processor::FakeClient.subscriptions.sole.processor_id, subscription.processor_subscription_id

    started = OutboxEvent.where(event_type: "billing.subscription.started")
    assert_equal 1, started.count
    payload = started.sole.data
    assert_equal "active", payload["status"]
    assert_equal subscription.id, payload["subscription_id"], "the event's subject is billing's own id, so a consumer joins on one key"
    assert_equal "buyer@example.com", payload["email"]
    assert_equal "Pro monthly", payload["plan_name"]

    invoice_paid = stripe_fixture("invoice.paid")
    post StripeWebhookHelpers::STRIPE_WEBHOOK_PATH, params: invoice_paid,
      headers: {
        "CONTENT_TYPE" => "application/json",
        "Stripe-Signature" => stripe_signature(invoice_paid)
      }
    assert_response :ok

    charge = Charge.sole
    assert_equal 8_700, charge.amount, "the amount is the fixture's own, 8700 — the recorder stores what the processor said, not what the plan costs"
    assert_equal "USD", charge.currency
    assert_equal ACCOUNT_ID, charge.account_id, "the account is denormalised at recording time, so the receipt needs no join"

    payment = OutboxEvent.where(event_type: "billing.payment.succeeded").sole
    assert_equal "sub_1PZQaBcDeFgHiJkLmNoPqR1", payment.subject
    assert_equal "pi_3PZQaBcDeFgHiJkLmNoPqR4", payment.data["payment_intent_id"]
    assert_equal "ch_3PZQaBcDeFgHiJkLmNoPqR6", charge.processor_charge_id

    get "/v1/charges/#{charge.id}"
    assert_response :ok
    assert_equal "text/html", response.media_type
    assert_includes response.body, "87.00 USD"
    assert_includes response.body, "ch_3PZQaBcDeFgHiJkLmNoPqR6"
    refute_includes response.body, "buyer@example.com"
    refute_includes response.body, ACCOUNT_ID

    get "/v1/subscriptions/#{subscription.id}/upcoming_invoice"
    assert_response :ok
    assert_equal 1_900, json_body.fetch("subtotal")

    get "/v1/subscriptions/#{subscription.id}/entitlements"
    assert_response :ok
    body = json_body
    assert_equal true, body.fetch("granted")
    assert_equal [ "Everything" ], body.fetch("features")
    assert_equal({ "projects" => 10 }, body.fetch("limits"))

    other_token_headers = auth_headers(account_id: OTHER_ACCOUNT_ID)
    get "/v1/charges/#{charge.id}", headers: other_token_headers
    assert_response :not_found
    get "/v1/subscriptions/#{subscription.id}", headers: other_token_headers
    assert_response :not_found
  end

  test "a second checkout for the same live plan refuses and disturbs nothing" do
    post "/v1/checkouts", params: { customer_id: @customer.id, plan_id: @plan.id }, as: :json
    assert_response :created
    first = Subscription.sole
    before = [ first.status, first.plan_id, first.updated_at ]

    post "/v1/checkouts", params: { customer_id: @customer.id, plan_id: @plan.id }, as: :json

    assert_response :unprocessable_entity
    assert_match(/already_subscribed/, response.body)
    assert_equal 1, Subscription.count
    assert_equal before, [ first.reload.status, first.plan_id, first.updated_at ]
    assert_equal 2, Processor::FakeClient.subscriptions.count
  end
end
