require "test_helper"

# /v1/checkouts — the development checkout door.
#
# The property that shapes every case here: **this door completes a checkout
# that the production door cannot.** `POST /v1/subscriptions` asks Stripe for a
# hosted session and writes nothing; this one goes through
# `Checkout::Session` and `Processor::FakeClient`, so a subscription exists when
# the response is rendered — and every guarantee that matters on the webhook
# path still holds: `Subscriptions::Lifecycle` is the only writer, the delivery
# is the normalised shape a processor event would carry, and the outbox event
# commits in the same transaction.
#
# The negative case is the point, as it is in the service specs. A completed
# checkout grants entitlements, so the direction that costs money is the write:
# a `customer_id` naming another account's customer is a 404 and the processor
# is never asked.
class V1CheckoutsTest < ActionDispatch::IntegrationTest
  IDEMPOTENCY_KEY = "3c9e1a74-5b62-4d8f-9e0a-7f1b2c3d4e5f".freeze

  # Same account the authentication helper's token names, for the reason
  # `customers_test.rb` gives: every `/v1` query is scoped by the token's
  # `account_id`, so a fixture owned by any other uuid is invisible to every
  # request made here.
  ACCOUNT_ID = TestSupport::TestIdentity::Account
  OTHER_OWNER_ID = "22222222-2222-4222-8222-222222222222".freeze

  setup do
    travel_to(frozen_now)
    Processor::FakeClient.reset!
    @customer = create_stripe_customer
    @plan = create_stripe_plan(price: Money.new(1900, "USD"))
  end

  # --- the happy path --------------------------------------------------------

  test "POST /v1/checkouts completes a checkout and returns the subscription" do
    post "/v1/checkouts", params: { customer_id: @customer.id, plan_id: @plan.id }, as: :json

    assert_response :created
    body = json_body
    assert_equal "active", body.fetch("status")
    assert_equal @plan.id, body.fetch("plan_id")
    assert_equal @customer.id, body.fetch("customer_id")
    assert_equal({ "amount_minor" => 1900, "currency" => "USD" }, body.fetch("price"))
    assert_match(/\Asub_FAKE[0-9a-f]{24}\z/, body.fetch("processor_subscription_id"))
  end

  test "POST /v1/checkouts writes the subscription, keyed by the processor's id" do
    post "/v1/checkouts", params: { customer_id: @customer.id, plan_id: @plan.id }, as: :json

    subscription = Subscription.sole
    assert_equal "active", subscription.status
    assert_equal ACCOUNT_ID, subscription.account_id
    assert_equal json_body.fetch("processor_subscription_id"), subscription.processor_subscription_id
    assert subscription.grants_entitlements?
  end

  test "POST /v1/checkouts publishes billing.subscription.started in the same commit" do
    assert_difference -> { OutboxEvent.where(event_type: "billing.subscription.started").count }, 1 do
      post "/v1/checkouts", params: { customer_id: @customer.id, plan_id: @plan.id }, as: :json
    end

    payload = OutboxEvent.find_by(event_type: "billing.subscription.started").data
    assert_equal "active", payload["status"]
    assert_equal @plan.id, payload["plan_id"]
    assert_equal ACCOUNT_ID, payload["account_id"]
    assert_nil payload["processor_event_id"]
  end

  test "POST /v1/checkouts buys the quantity it was asked for" do
    post "/v1/checkouts",
      params: { customer_id: @customer.id, plan_id: @plan.id, quantity: 7 },
      as: :json

    assert_response :created
    # The quantity reaches the processor and the event: a `Subscription` has no
    # quantity column and must never grow one — which is the whole point of the
    # assertion being about what was asked and what was published.
    assert_equal 7, Processor::FakeClient.subscriptions.sole.quantity
    assert_equal 7, OutboxEvent.find_by(event_type: "billing.subscription.started").data["quantity"]
  end

  # --- the negative case, which is what the door is really about ---------------

  # The scope is the resolution, not a check after it: a `customer_id` naming
  # another account's customer resolves to nil inside `Customer.for_account`,
  # which is the same answer the production door's own `find_or_refuse` gives
  # for a uuid this service does not hold — the door refuses before the
  # processor is asked, which is the direction that costs money.
  test "POST /v1/checkouts refuses another account's customer and writes nothing" do
    other = create_stripe_customer(account_id: OTHER_OWNER_ID)

    post "/v1/checkouts", params: { customer_id: other.id, plan_id: @plan.id }, as: :json

    assert_response :unprocessable_entity
    assert_includes problem_fields, "customer_id"
    assert_equal 0, Subscription.count
    assert_empty Processor::FakeClient.subscriptions
  end

  test "POST /v1/checkouts refuses a user-owned customer" do
    user_owned = create_stripe_customer(owner_type: "User")

    post "/v1/checkouts", params: { customer_id: user_owned.id, plan_id: @plan.id }, as: :json

    assert_response :unprocessable_entity
    assert_includes problem_fields, "customer_id"
    assert_equal 0, Subscription.count
  end

  test "POST /v1/checkouts refuses a plan that is not for sale" do
    withdrawn = create_stripe_plan(name: "Withdrawn").tap { |plan| plan.update!(active: false) }

    post "/v1/checkouts", params: { customer_id: @customer.id, plan_id: withdrawn.id }, as: :json

    assert_response :unprocessable_entity
    assert_includes problem_fields, "plan_id"
    assert_equal 0, Subscription.count
  end

  test "POST /v1/checkouts refuses a plan the processor cannot charge for" do
    # The fixture helper hands every plan a price, so this one has it taken away:
    # a plan with no `processor_price_id` is a plan that cannot be bought, and
    # asking the processor anyway would start a subscription at whatever its
    # default happens to be.
    unpriced = create_stripe_plan(name: "Unpriced").tap { |plan| plan.update!(processor_price_id: nil) }

    post "/v1/checkouts", params: { customer_id: @customer.id, plan_id: unpriced.id }, as: :json

    assert_response :unprocessable_entity
    assert_includes problem_fields, "plan_id"
    assert_equal 0, Subscription.count
  end

  test "POST /v1/checkouts answers 422 when the lifecycle refuses" do
    Subscription.create!(
      account_id: ACCOUNT_ID, customer: @customer, plan: @plan,
      processor_subscription_id: "sub_FAKEexisting0000000", status: "active"
    )

    post "/v1/checkouts", params: { customer_id: @customer.id, plan_id: @plan.id }, as: :json

    assert_response :unprocessable_entity
    body = json_body
    assert_match(/already_subscribed/, body.fetch("detail"))
    assert_equal 1, Subscription.count
  end

  # A door that fabricates an active subscription from a request body is a
  # free-subscription door the day it is reachable in a deployment somebody can
  # call. It answers the same 404 a uuid naming nothing gets, so a caller learns
  # nothing about the deployment's configuration from it.
  test "POST /v1/checkouts answers 404 when the fake door is not enabled" do
    with_production_env_and_disabled_door do
      post "/v1/checkouts", params: { customer_id: @customer.id, plan_id: @plan.id }, as: :json
    end

    assert_response :not_found
    assert_equal 0, Subscription.count
  end

  # --- idempotency, exactly like the production door --------------------------

  test "POST /v1/checkouts replays a stored response for the same key and body" do
    post "/v1/checkouts",
      params: { customer_id: @customer.id, plan_id: @plan.id },
      headers: { "Idempotency-Key" => IDEMPOTENCY_KEY },
      as: :json
    assert_response :created

    post "/v1/checkouts",
      params: { customer_id: @customer.id, plan_id: @plan.id },
      headers: { "Idempotency-Key" => IDEMPOTENCY_KEY },
      as: :json

    assert_response :created
    assert_equal "true", response.headers["Idempotency-Replayed"]
    assert_equal 1, Subscription.count
  end

  test "POST /v1/checkouts is a 409 for the same key and a different body" do
    post "/v1/checkouts",
      params: { customer_id: @customer.id, plan_id: @plan.id },
      headers: { "Idempotency-Key" => IDEMPOTENCY_KEY },
      as: :json

    other_plan = create_stripe_plan(price: Money.new(4900, "USD"))
    post "/v1/checkouts",
      params: { customer_id: @customer.id, plan_id: other_plan.id },
      headers: { "Idempotency-Key" => IDEMPOTENCY_KEY },
      as: :json

    assert_response :conflict
  end

  # --- the development loop, after the door has completed ----------------------
  #
  # What the walk on the whole stack (2026-10-16) found after this door: the
  # subscription completes, and then every management action asked STRIPE about
  # a subscription Stripe never held — "has no upcoming invoice at the payment
  # processor" for a projection the fake could have answered, and the same
  # translation for a cancel. Two answers here, and each is the honest one: the
  # projection comes from the fake's own books, and the verbs the fake does not
  # have are refused by name, saying which processor holds the row.

  test "the projection comes from the fake's own books and never reaches for Stripe" do
    # A real double on the Stripe seat, so "the fake answered it" is measured
    # rather than assumed: the request the real client would have asked for is
    # absent, and the response is the fake's own projection of the plan the
    # door sold.
    @api = FakeStripeAPI.new
    @previous_processor = Processor::StripeClient.current
    Processor::StripeClient.current = Processor::StripeClient.new(api_key: "sk_test", api: @api)

    post "/v1/checkouts", params: { customer_id: @customer.id, plan_id: @plan.id }, as: :json
    assert_response :created
    subscription = Subscription.sole

    get "/v1/subscriptions/#{subscription.id}/upcoming_invoice"

    assert_response :ok
    assert_equal 1_900, json_body.fetch("subtotal")
    assert_empty @api.requests, "the fake's own subscription must not be asked of the real processor"
  ensure
    Processor::StripeClient.current = @previous_processor
  end

  test "cancel is refused by name, naming the processor that holds the row" do
    post "/v1/checkouts", params: { customer_id: @customer.id, plan_id: @plan.id }, as: :json
    subscription = Subscription.sole

    post "/v1/subscriptions/#{subscription.id}/cancel", params: { at_period_end: true }, as: :json

    assert_response :unprocessable_entity
    assert_includes problem_fields, "subscription_id"
    assert_match(/development processor/, json_body.fetch("detail"))
  end

  test "a plan change is refused by name on the same terms" do
    post "/v1/checkouts", params: { customer_id: @customer.id, plan_id: @plan.id }, as: :json
    subscription = Subscription.sole
    other_plan = create_stripe_plan(price: Money.new(4900, "USD"))

    post "/v1/subscriptions/#{subscription.id}/change_plan", params: { plan_id: other_plan.id }, as: :json

    assert_response :unprocessable_entity
    assert_includes problem_fields, "subscription_id"
  end

  test "the portal is refused by name too: a card form is the processor's" do
    post "/v1/checkouts", params: { customer_id: @customer.id, plan_id: @plan.id }, as: :json
    subscription = Subscription.sole

    post "/v1/subscriptions/#{subscription.id}/payment_method",
      params: { return_url: "https://app.cafaye.com/billing" }, as: :json

    assert_response :unprocessable_entity
    assert_includes problem_fields, "subscription_id"
  end

  private
    # Production and the door disabled, for the duration of the block, and the
    # previous values back afterwards — including "was not set at all", which
    # is what makes the second request in the same process honest about what
    # the first one proved.
    def with_production_env_and_disabled_door
      previous_env = ENV["BILLING_FAKE_PROCESSOR_ENABLED"]
      ENV["BILLING_FAKE_PROCESSOR_ENABLED"] = "false"
      simple_stubs.stub_object(Rails, :env) { ActiveSupport::StringInquirer.new("production") }
      yield
    ensure
      simple_stubs.unstub_all!
      ENV["BILLING_FAKE_PROCESSOR_ENABLED"] = previous_env
    end

    def problem_fields
      json_body.fetch("errors").map { |error| error.fetch("field") }
    end
end
