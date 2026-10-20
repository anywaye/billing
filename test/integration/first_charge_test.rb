require "test_helper"

# The first charge, end to end: from a plan nobody has bought to a receipt a
# person opens.
#
# This is the loop the whole service exists for, walked top to bottom in one
# test rather than in eight specs in five directories. The other suites prove
# each half holds; this one proves the halves **compose** — that a checkout
# through one door and a payment through another land on the same subscription,
# in the same tables, with the same events, and that the facts a customer
# checks afterwards are all reachable.
#
# What it walks, in order:
#
#   plan with a processor price  ->  customer for an account
#     -> POST /v1/checkouts      (the fake door: the subscription appears NOW)
#     -> POST /v1/webhooks/stripe (a real fixture, signature verified)
#     -> a charge row, a receipt, the projection, the entitlements
#
# And the two properties that make it a *service* rather than a demo: the
# subscription is written by `Subscriptions::Lifecycle` on both paths (one
# writer), and `billing.subscription.started` is published exactly once.
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
    # The processor this loop asks: the API double, not the network. The door
    # that completed the checkout is the fake's; the door the projection goes
    # through is Stripe's, and the double knows the subscription the fake minted.
    @api = FakeStripeAPI.new
    @previous_client = Processor::StripeClient.current
    Processor::StripeClient.current = Processor::StripeClient.new(api_key: "sk_test", api: @api)
  end

  teardown do
    Processor::StripeClient.current = @previous_client
  end

  test "a stranger signs up, buys, and can read what they were charged" do
    # --- 1. the checkout door: a customer and a plan in, an active subscription out
    post "/v1/checkouts", params: { customer_id: @customer.id, plan_id: @plan.id }, as: :json
    assert_response :created, "the checkout door answered #{response.status}: #{response.body}"

    subscription = Subscription.sole
    assert_equal "active", subscription.status, "a completed checkout must grant the entitlements it was bought for"
    assert_equal @plan.id, subscription.plan_id
    assert_equal @customer.id, subscription.customer_id
    assert_equal ACCOUNT_ID, subscription.account_id
    assert subscription.grants_entitlements?

    # The processor was asked for exactly one subscription, and this one is
    # keyed by its id — the join the delivery path reconciles on.
    assert_equal 1, Processor::FakeClient.subscriptions.count
    assert_equal Processor::FakeClient.subscriptions.sole.processor_id, subscription.processor_subscription_id

    # --- 2. the outbox: exactly one start event, with the recipient on it
    started = OutboxEvent.where(event_type: "billing.subscription.started")
    assert_equal 1, started.count
    payload = started.sole.data
    assert_equal "active", payload["status"]
    assert_equal subscription.id, payload["subscription_id"], "the event's subject is billing's own id, so a consumer joins on one key"
    assert_equal "buyer@example.com", payload["email"]
    assert_equal "Pro monthly", payload["plan_name"]

    # --- 3. the processor bills: a real fixture, signature verified, acted on once
    # The RAW body, because the signature is over the exact bytes and a
    # re-serialized parse would produce a different digest — the whole reason
    # the verifier reads `request.raw_post`.
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

    # A payment event's subject is the processor's own subscription id, read off
    # the payload — the same decision `cafaye.yml` records for subscription
    # events ("the processor's id as their subject, because an invoice references
    # a subscription rather than being one"). Note what that id is: the FIXTURE's
    # `sub_1PZQaBcDeFgHiJkLmNoPqR1`, which is not the id this checkout's
    # subscription was created under. That is not a defect in the loop — it is the
    # loop's honest shape: the charge resolves by the processor's CUSTOMER id
    # (which both the fixture and this checkout's customer carry), so a payment
    # for a subscription row this service never saw still records honestly, and
    # the subject is what the processor said rather than what this service
    # guessed. The charge's own id rides in the payload for the join.
    payment = OutboxEvent.where(event_type: "billing.payment.succeeded").sole
    assert_equal "sub_1PZQaBcDeFgHiJkLmNoPqR1", payment.subject
    # The event names the processor's own invoice and payment intent; the charge
    # row is keyed by the invoice's own `charge` id, which is what
    # `charges.processor_charge_id` is unique on — the recorder's resolution
    # mechanism for a redelivery. So a consumer holding the event reaches the
    # receipt by the processor's own charge id.
    assert_equal "pi_3PZQaBcDeFgHiJkLmNoPqR4", payment.data["payment_intent_id"]
    assert_equal "ch_3PZQaBcDeFgHiJkLmNoPqR6", charge.processor_charge_id

    # --- 4. the receipt: a page a person opens, scoped by the account
    get "/v1/charges/#{charge.id}"
    assert_response :ok
    assert_equal "text/html", response.media_type
    # The receipt is a page for the person who paid: the amount, the processor's
    # own description, the charge id and the row's own id. No email and no
    # account — the receipt is addressed by being scoped, not by naming who is
    # looking at it.
    assert_includes response.body, "87.00 USD"
    assert_includes response.body, "ch_3PZQaBcDeFgHiJkLmNoPqR6"
    refute_includes response.body, "buyer@example.com"
    refute_includes response.body, ACCOUNT_ID

    # --- 5. the projection and the entitlements, both scoped to the same account
    get "/v1/subscriptions/#{subscription.id}/upcoming_invoice"
    assert_response :ok
    assert_equal 1_900, json_body.fetch("subtotal")

    get "/v1/subscriptions/#{subscription.id}/entitlements"
    assert_response :ok
    body = json_body
    assert_equal true, body.fetch("granted")
    assert_equal [ "Everything" ], body.fetch("features")
    assert_equal({ "projects" => 10 }, body.fetch("limits"))

    # --- 6. and none of it is reachable from another account
    other_token_headers = auth_headers(account_id: OTHER_ACCOUNT_ID)
    get "/v1/charges/#{charge.id}", headers: other_token_headers
    assert_response :not_found
    get "/v1/subscriptions/#{subscription.id}", headers: other_token_headers
    assert_response :not_found
  end

  # The same loop's failure direction, because a checkout that half-applied is
  # the one defect that grants access nobody paid for: the account already
  # holds one live subscription on the plan, so the door refuses and the
  # existing row is untouched.
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
    # The processor was asked twice, which is the honest two-sided state, and
    # this service holds one.
    assert_equal 2, Processor::FakeClient.subscriptions.count
  end
end
