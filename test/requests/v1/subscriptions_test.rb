require "test_helper"

class V1SubscriptionsTest < ActionDispatch::IntegrationTest
  IDEMPOTENCY_KEY = "6f1c3a52-9d84-4f0e-b7a2-1c5e8d3f6b90".freeze
  OTHER_IDEMPOTENCY_KEY = "0b7d2e14-58ca-4a36-9f1e-3d2b6c4a8e51".freeze

  ACCOUNT_ID = TestSupport::TestIdentity::Account
  OTHER_OWNER_ID = "22222222-2222-4222-8222-222222222222".freeze

  setup do
    travel_to(frozen_now)
    @api = FakeStripeAPI.new
    @previous_processor = Processor::StripeClient.current
    @processor_under_test = Processor::StripeClient.new(api_key: "sk_test", api: @api)
    Processor::StripeClient.current = @processor_under_test
    @customer = create_stripe_customer
    @plan = create_stripe_plan(price: Billing::Money.new(1900, "USD"))
    @team = create_stripe_plan(price: Billing::Money.new(4900, "USD"))
    @subscription = create_subscription(plan: @plan)
  end

  teardown do
    Processor::StripeClient.current = @previous_processor
  end


  test "POST /v1/subscriptions creates a checkout session" do
    post "/v1/subscriptions", params: { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" }, as: :json

    assert_response :created
    assert_equal 1, @api.requests.size
    assert_equal "subscription", @api.requests.last.fetch(:mode)
  end

  test "POST /v1/subscriptions returns the processor's own checkout url" do
    post "/v1/subscriptions", params: { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" }, as: :json

    assert_equal "https://checkout.stripe.test/c/pay/cs_test_00000000000001", json_body.fetch("checkout_url")
  end

  test "POST /v1/subscriptions returns the processor's own session id" do
    post "/v1/subscriptions", params: { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" }, as: :json

    assert_equal "cs_test_00000000000001", json_body.fetch("checkout_session_id")
  end

  test "POST /v1/subscriptions checks out the plan that was asked for" do
    post "/v1/subscriptions", params: { customer_id: @customer.id, plan_id: @team.id, success_url: "https://app.anywaye.com/billing" }, as: :json

    assert_equal [ { price: @team.processor_price_id, quantity: 1 } ], @api.requests.last.fetch(:line_items)
  end

  test "POST /v1/subscriptions writes no subscription yet" do
    post "/v1/subscriptions", params: { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" }, as: :json

    assert_equal 1, Subscription.count, "a subscription must not exist until a webhook says one does"
  end

  test "POST /v1/subscriptions names no path, because there is no resource to point at" do
    post "/v1/subscriptions", params: { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" }, as: :json

    assert_nil response.headers["Location"]
  end

  test "POST /v1/subscriptions is not idempotent by itself" do
    post "/v1/subscriptions", params: { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" }, as: :json
    post "/v1/subscriptions", params: { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" }, as: :json

    assert_equal 2, @api.requests.size
    assert_equal "cs_test_00000000000002", json_body.fetch("checkout_session_id")
  end

  test "POST /v1/subscriptions is a 422 for a plan that does not exist" do
    post "/v1/subscriptions", params: { customer_id: @customer.id, plan_id: SecureRandom.uuid }, as: :json

    assert_response :unprocessable_entity
    assert_equal [ "plan_id" ], problem_codes
    assert_empty @api.requests
  end

  test "POST /v1/subscriptions is a 422 for a customer that does not exist" do
    post "/v1/subscriptions", params: { customer_id: SecureRandom.uuid, plan_id: @plan.id }, as: :json

    assert_response :unprocessable_entity
    assert_equal [ "customer_id" ], problem_codes
    assert_empty @api.requests
  end

  test "POST /v1/subscriptions is a 422 when the body leaves both fields out" do
    post "/v1/subscriptions", params: {}, as: :json

    assert_response :unprocessable_entity
    assert_equal %w[customer_id plan_id], problem_codes.sort
  end

  test "POST /v1/subscriptions is a 422 for a plan with no processor price" do
    @plan.update!(processor_price_id: nil)

    post "/v1/subscriptions", params: { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" }, as: :json

    assert_response :unprocessable_entity
    assert_equal [ "plan_id" ], problem_codes
    assert_empty @api.requests
  end

  test "POST /v1/subscriptions is a 422 for a plan that is not for sale" do
    @plan.update!(active: false)

    post "/v1/subscriptions", params: { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" }, as: :json

    assert_response :unprocessable_entity
    assert_equal [ "plan_id" ], problem_codes
    assert_empty @api.requests
  end

  test "POST /v1/subscriptions is a 422 for a customer that belongs to a user" do
    user_owned = create_stripe_customer(owner_type: "User")

    post "/v1/subscriptions", params: { customer_id: user_owned.id, plan_id: @plan.id }, as: :json

    assert_response :unprocessable_entity
    assert_equal [ "customer_id" ], problem_codes
  end

  test "POST /v1/subscriptions is a 422 for an id that is not a uuid" do
    post "/v1/subscriptions", params: { customer_id: "not-a-uuid", plan_id: @plan.id }, as: :json

    assert_response :not_found
  end

  test "POST /v1/subscriptions is a 503 when the processor is not configured" do
    with_unconfigured_processor do
      post "/v1/subscriptions", params: { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" }, as: :json
    end

    assert_response :service_unavailable
    assert_problem "unavailable"
  end

  test "POST /v1/subscriptions reports a processor refusal as a 422, not a 500" do
    @plan.update!(processor_price_id: "price_gone")

    post "/v1/subscriptions", params: { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" }, as: :json

    assert_response :unprocessable_entity
  end

  test "POST /v1/subscriptions never echoes a processor's internal message to the client" do
    @plan.update!(processor_price_id: "price_gone")

    post "/v1/subscriptions", params: { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" }, as: :json

    refute_match(/No such price/, response.body)
  end


  test "the same key twice creates one checkout session" do
    2.times { post_with_key(IDEMPOTENCY_KEY, { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" }) }

    assert_equal 1, @api.requests.size
  end

  test "the same key twice returns the same bytes" do
    post_with_key(IDEMPOTENCY_KEY, { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" })
    first = response.body
    post_with_key(IDEMPOTENCY_KEY, { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" })

    assert_equal first, response.body
  end

  test "the same key twice says the second response was a replay" do
    post_with_key(IDEMPOTENCY_KEY, { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" })
    post_with_key(IDEMPOTENCY_KEY, { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" })

    assert_equal "true", response.headers["Idempotency-Replayed"]
  end

  test "the same key twice returns the same status" do
    post_with_key(IDEMPOTENCY_KEY, { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" })
    first = response.status
    post_with_key(IDEMPOTENCY_KEY, { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" })

    assert_equal first, response.status
  end

  test "the same key with a different body is a 409" do
    post_with_key(IDEMPOTENCY_KEY, { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" })
    post_with_key(IDEMPOTENCY_KEY, { customer_id: @customer.id, plan_id: @team.id })

    assert_response :conflict
    assert_problem "idempotency_key_reused"
  end

  test "the same key with a different body makes no second request to the processor" do
    post_with_key(IDEMPOTENCY_KEY, { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" })
    post_with_key(IDEMPOTENCY_KEY, { customer_id: @customer.id, plan_id: @team.id })

    assert_equal 1, @api.requests.size
  end

  test "the same key on a different endpoint is a different key" do
    post_with_key(IDEMPOTENCY_KEY, { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" })
    post_with_key(IDEMPOTENCY_KEY, { at_period_end: true }, to: cancel_path)

    assert_response :ok
    refute_equal "true", response.headers["Idempotency-Replayed"]
  end


  test "GET /v1/subscriptions lists them" do
    get "/v1/subscriptions"

    assert_response :ok
    assert_equal [ @subscription.id ], json_body.fetch("data").map { |row| row.fetch("id") }
  end

  test "GET /v1/subscriptions pages with data and a page, as core requires" do
    get "/v1/subscriptions"

    assert_equal %w[has_more next_cursor], json_body.fetch("page").keys.sort
  end

  test "GET /v1/subscriptions returns an empty array rather than nothing" do
    Subscription.delete_all
    get "/v1/subscriptions"

    assert_equal [], json_body.fetch("data")
  end

  test "GET /v1/subscriptions/:id returns the subscription" do
    get "/v1/subscriptions/#{@subscription.id}"

    assert_response :ok
    assert_equal "active", json_body.fetch("status")
  end

  test "GET /v1/subscriptions/:id carries the plan's price in integer minor units" do
    get "/v1/subscriptions/#{@subscription.id}"

    assert_equal 1900, json_body.fetch("price").fetch("amount_minor")
    assert_instance_of Integer, json_body.fetch("price").fetch("amount_minor")
  end

  test "GET /v1/subscriptions/:id is a 404 for a subscription that does not exist" do
    get "/v1/subscriptions/#{SecureRandom.uuid}"

    assert_response :not_found
    assert_problem "not_found"
  end

  test "GET /v1/subscriptions/:id is a 404 for an id that is not a uuid" do
    get "/v1/subscriptions/nonsense"

    assert_response :not_found
  end

  test "a cancelled subscription is still readable" do
    @subscription.update!(status: "canceled")
    get "/v1/subscriptions/#{@subscription.id}"

    assert_response :ok
    assert_equal "canceled", json_body.fetch("status")
  end


  test "cancelling asks the processor to cancel" do
    post cancel_path, params: { at_period_end: true }, as: :json

    assert_response :ok
    assert_equal @subscription.processor_subscription_id, @api.requests.last.fetch(:id)
  end

  test "cancelling at the period end says so to the processor" do
    post cancel_path, params: { at_period_end: true }, as: :json

    assert_equal true, @api.requests.last.fetch(:cancel_at_period_end)
  end

  test "cancelling now says so to the processor" do
    post cancel_path, params: { at_period_end: false }, as: :json

    assert_equal false, @api.requests.last.fetch(:cancel_at_period_end)
  end

  test "cancelling asks the processor for no refund and no proration" do
    post cancel_path, params: { at_period_end: false }, as: :json

    refute @api.requests.last.key?(:refund)
    refute @api.requests.last.key?(:prorate)
    refute @api.requests.last.key?(:amount)
  end

  test "cancelling does not change the subscription locally" do
    post cancel_path, params: { at_period_end: true }, as: :json

    assert_equal "active", @subscription.reload.status
  end

  test "cancelling returns the subscription as it is, not as the processor will make it" do
    post cancel_path, params: { at_period_end: true }, as: :json

    assert_equal "active", json_body.fetch("status")
  end

  test "cancelling is a 422 when the body does not say when" do
    post cancel_path, params: {}, as: :json

    assert_response :unprocessable_entity
    assert_equal [ "at_period_end" ], problem_codes
    assert_empty @api.requests
  end

  test "cancelling is a 422 when the body says something that is not a boolean" do
    post cancel_path, params: { at_period_end: "later" }, as: :json

    assert_response :unprocessable_entity
    assert_equal [ "at_period_end" ], problem_codes
    assert_empty @api.requests
  end

  test "cancelling a cancelled subscription is a 409" do
    @subscription.update!(status: "canceled")

    post cancel_path, params: { at_period_end: true }, as: :json

    assert_response :conflict
    assert_empty @api.requests
  end

  test "cancelling a past-due subscription at the period end is a 422" do
    @subscription.update!(status: "past_due")

    post cancel_path, params: { at_period_end: true }, as: :json

    assert_response :unprocessable_entity
    assert_equal [ "at_period_end" ], problem_codes
    assert_empty @api.requests
  end

  test "cancelling a past-due subscription now is allowed" do
    @subscription.update!(status: "past_due")

    post cancel_path, params: { at_period_end: false }, as: :json

    assert_response :ok
    assert_equal false, @api.requests.last.fetch(:cancel_at_period_end)
  end

  test "cancelling an unpaid subscription is a 409" do
    @subscription.update!(status: "unpaid")

    post cancel_path, params: { at_period_end: false }, as: :json

    assert_response :conflict
  end

  test "cancelling a subscription that does not exist is a 404" do
    post "/v1/subscriptions/#{SecureRandom.uuid}/cancel", params: { at_period_end: true }, as: :json

    assert_response :not_found
  end

  test "cancelling a subscription the processor does not have is a 422" do
    @subscription.update!(processor_subscription_id: "sub_unknown")

    post cancel_path, params: { at_period_end: true }, as: :json

    assert_response :unprocessable_entity
  end

  test "cancelling accepts an idempotency key" do
    post_with_key(IDEMPOTENCY_KEY, { at_period_end: true }, to: cancel_path)

    assert_response :ok
  end

  test "cancelling twice with the same key asks the processor once" do
    2.times { post_with_key(IDEMPOTENCY_KEY, { at_period_end: true }, to: cancel_path) }

    assert_equal 1, @api.requests.size
  end

  test "cancelling twice with the same key replays the first answer" do
    post_with_key(IDEMPOTENCY_KEY, { at_period_end: true }, to: cancel_path)
    post_with_key(IDEMPOTENCY_KEY, { at_period_end: true }, to: cancel_path)

    assert_equal "true", response.headers["Idempotency-Replayed"]
  end


  test "changing plan moves the processor's subscription onto the new price" do
    post change_plan_path, params: { plan_id: @team.id }, as: :json

    assert_response :ok
    move = @api.requests.last
    assert_equal [ { id: "si_FAKE1PZQaBcDeFgHiJkLmNoPqR1", price: @team.processor_price_id } ],
      move.fetch(:items)
  end

  test "an upgrade is invoiced immediately" do
    post change_plan_path, params: { plan_id: @team.id }, as: :json

    assert_equal "always_invoice", @api.requests.last.fetch(:proration_behavior)
  end

  test "a downgrade carries nothing forward" do
    post change_plan_path, params: { plan_id: downgrade_plan.id }, as: :json

    assert_equal "none", @api.requests.last.fetch(:proration_behavior)
  end

  test "a change to the same price carries nothing forward" do
    lateral = create_stripe_plan(price: Billing::Money.new(1900, "USD"))

    post change_plan_path, params: { plan_id: lateral.id }, as: :json

    assert_equal "none", @api.requests.last.fetch(:proration_behavior)
  end

  test "a change to a plan on a different interval is refused" do
    yearly = create_stripe_plan(price: Billing::Money.new(19_000, "USD"), interval: "year")

    post change_plan_path, params: { plan_id: yearly.id }, as: :json

    assert_response :unprocessable_entity
    assert_equal [ "plan_id" ], problem_codes
    assert_empty @api.requests
  end

  test "a change to a plan in a different currency is refused" do
    euros = Plan.create!(name: "Pro EUR", slug: "pro-eur", price: Billing::Money.new(1900, "EUR"), interval: "month",
      processor_price_id: "price_FAKEeuroplanBBBBBBBBB")

    post change_plan_path, params: { plan_id: euros.id }, as: :json

    assert_response :unprocessable_entity
    assert_equal [ "plan_id" ], problem_codes
    assert_empty @api.requests
  end

  test "a change never asks the processor for a credit or a refund amount" do
    post change_plan_path, params: { plan_id: @team.id }, as: :json

    refute @api.requests.last.key?(:amount)
    refute @api.requests.last.key?(:credit)
    refute @api.requests.last.key?(:refund)
  end

  test "a change does not move the plan locally" do
    post change_plan_path, params: { plan_id: @team.id }, as: :json

    assert_equal @plan, @subscription.reload.plan
  end

  test "a change says when it takes effect, because the local row will not show it yet" do
    post change_plan_path, params: { plan_id: @team.id }, as: :json

    assert_equal "immediately", json_body.fetch("plan_change").fetch("effective")
  end

  test "a change to a cheaper plan says it takes effect at the period end" do
    post change_plan_path, params: { plan_id: downgrade_plan.id }, as: :json

    assert_equal "period_end", json_body.fetch("plan_change").fetch("effective")
  end

  test "a change names the plan it is going to" do
    post change_plan_path, params: { plan_id: @team.id }, as: :json

    assert_equal @team.id, json_body.fetch("plan_change").fetch("plan_id")
  end

  test "a change to a plan that does not exist is a 422" do
    post change_plan_path, params: { plan_id: SecureRandom.uuid }, as: :json

    assert_response :unprocessable_entity
    assert_equal [ "plan_id" ], problem_codes
  end

  test "a change to a plan with no processor price is a 422" do
    @team.update!(processor_price_id: nil)

    post change_plan_path, params: { plan_id: @team.id }, as: :json

    assert_response :unprocessable_entity
    assert_equal [ "plan_id" ], problem_codes
    assert_empty @api.requests
  end

  test "a change to a plan that is not for sale is a 422" do
    @team.update!(active: false)

    post change_plan_path, params: { plan_id: @team.id }, as: :json

    assert_response :unprocessable_entity
  end

  test "changing a cancelled subscription is a 409" do
    @subscription.update!(status: "canceled")

    post change_plan_path, params: { plan_id: @team.id }, as: :json

    assert_response :conflict
    assert_empty @api.requests
  end

  test "changing an unpaid subscription is a 409" do
    @subscription.update!(status: "unpaid")

    post change_plan_path, params: { plan_id: @team.id }, as: :json

    assert_response :conflict
  end

  test "a change to the plan it is already on is allowed and changes nothing" do
    post change_plan_path, params: { plan_id: @plan.id }, as: :json

    assert_response :ok
    assert_equal "none", @api.requests.last.fetch(:proration_behavior)
  end

  test "changing a past-due subscription is allowed" do
    @subscription.update!(status: "past_due")

    post change_plan_path, params: { plan_id: @team.id }, as: :json

    assert_response :ok
  end

  test "a change accepts an idempotency key" do
    post_with_key(IDEMPOTENCY_KEY, { plan_id: @team.id }, to: change_plan_path)

    assert_response :ok
  end

  test "changing twice with the same key asks the processor once" do
    2.times { post_with_key(IDEMPOTENCY_KEY, { plan_id: @team.id }, to: change_plan_path) }

    moves = @api.requests.reject { |request| request[:call] == :retrieve }
    assert_equal 1, moves.size
    assert_equal 2, @api.requests.size
  end


  test "the entitlements endpoint returns what the plan grants" do
    @plan.update!(entitlements: { "features" => %w[dashboards exports], "limits" => { "seats" => 5 } })

    get entitlements_path

    assert_response :ok
    assert_equal %w[dashboards exports], json_body.fetch("features")
    assert_equal({ "seats" => 5 }, json_body.fetch("limits"))
  end

  test "the entitlements endpoint names the subscription and the plan" do
    get entitlements_path

    assert_equal @subscription.id, json_body.fetch("subscription_id")
    assert_equal @plan.id, json_body.fetch("plan_id")
    assert_equal "active", json_body.fetch("status")
  end

  test "the entitlements endpoint says the subscription is granted while it is live" do
    get entitlements_path

    assert_equal true, json_body.fetch("granted")
  end

  Subscription::LIVE_STATUSES.each do |status|
    test "a #{status} subscription still grants what the plan grants" do
      @subscription.update!(status: status)

      get entitlements_path

      assert_equal true, json_body.fetch("granted")
    end
  end

  test "a cancelled subscription grants nothing" do
    @plan.update!(entitlements: { "features" => %w[dashboards], "limits" => {} })
    @subscription.update!(status: "canceled")

    get entitlements_path

    assert_equal false, json_body.fetch("granted")
    assert_equal [], json_body.fetch("features")
    assert_equal({}, json_body.fetch("limits"))
  end

  test "the entitlements endpoint is a 404 for a subscription that does not exist" do
    get "/v1/subscriptions/#{SecureRandom.uuid}/entitlements"

    assert_response :not_found
  end

  test "a plan with no entitlements grants an empty set rather than nothing" do
    get entitlements_path

    assert_equal [], json_body.fetch("features")
    assert_equal({}, json_body.fetch("limits"))
  end

  test "the entitlements endpoint carries a trace id like every other response" do
    get entitlements_path

    assert_predicate trace_id_header, :present?
  end


  test "POST /v1/subscriptions/:id/payment_method returns the processor's portal url" do
    post "/v1/subscriptions/#{@subscription.id}/payment_method",
      params: { return_url: "https://app.anywaye.com/billing/subscriptions" }, as: :json

    assert_response :ok
    assert_equal "https://billing.stripe.test/session/pcss_00000000000001", json_body.fetch("payment_method_url")

    request = @api.requests.last
    assert_equal @customer.processor_customer_id, request.fetch(:customer)
    assert_equal "https://app.anywaye.com/billing/subscriptions", request.fetch(:return_url)
  end

  test "POST /v1/subscriptions/:id/payment_method is a 404 for another account's subscription" do
    other_customer = create_stripe_customer(account_id: OTHER_OWNER_ID, processor_customer_id: "cus_FAKEsomebodyelseBBBBBB")
    other_subscription = Subscription.create!(
      account_id: OTHER_OWNER_ID, customer: other_customer, plan: @plan,
      processor_subscription_id: "sub_FAKEotherXXXXXXX", status: "active"
    )

    post "/v1/subscriptions/#{other_subscription.id}/payment_method",
      params: { return_url: "https://app.anywaye.com/billing/subscriptions" }, as: :json

    assert_response :not_found
    assert_empty @api.requests
  end

  [
    "/billing",
    "//evil.test/x",
    "not a url"
  ].each do |unreturnable|
    test "POST /v1/subscriptions/:id/payment_method refuses a return_url of #{unreturnable}" do
      post "/v1/subscriptions/#{@subscription.id}/payment_method",
        params: { return_url: unreturnable }, as: :json

      assert_response :unprocessable_entity
      assert_includes json_body.fetch("errors").map { |error| error.fetch("field") }, "return_url"
      assert_empty @api.requests
    end
  end

  test "POST /v1/subscriptions/:id/payment_method requires a return_url" do
    post "/v1/subscriptions/#{@subscription.id}/payment_method", as: :json

    assert_response :unprocessable_entity
    assert_includes json_body.fetch("errors").map { |error| error.fetch("field") }, "return_url"
  end

  test "POST /v1/subscriptions/:id/payment_method is a 422 for a customer the processor does not know" do
    @subscription.customer.update!(processor_customer_id: nil)

    post "/v1/subscriptions/#{@subscription.id}/payment_method",
      params: { return_url: "https://app.anywaye.com/billing" }, as: :json

    assert_response :unprocessable_entity
    assert_includes json_body.fetch("errors").map { |error| error.fetch("field") }, "subscription_id"
  end

  test "POST /v1/subscriptions/:id/payment_method is a 503 when the processor is unconfigured" do
    Processor::StripeClient.current = Processor::StripeClient.new(api_key: nil)

    post "/v1/subscriptions/#{@subscription.id}/payment_method",
      params: { return_url: "https://app.anywaye.com/billing" }, as: :json

    assert_response :service_unavailable
  end


  test "every subscription path is served" do
    get "/v1/subscriptions"
    assert_response :ok
    get "/v1/subscriptions/#{@subscription.id}"
    assert_response :ok
    post "/v1/subscriptions", params: { customer_id: @customer.id, plan_id: @plan.id, success_url: "https://app.anywaye.com/billing" }, as: :json
    assert_response :created
    post cancel_path, params: { at_period_end: true }, as: :json
    assert_response :ok
    post change_plan_path, params: { plan_id: @team.id }, as: :json
    assert_response :ok
    get entitlements_path
    assert_response :ok
  end

  test "the endpoints are declared in the OpenAPI document" do
    document = YAML.load_file(Rails.root.join("openapi/v1.yaml"))

    assert_equal(
      %w[
        /v1/subscriptions
        /v1/subscriptions/{id}
        /v1/subscriptions/{id}/cancel
        /v1/subscriptions/{id}/change_plan
        /v1/subscriptions/{id}/entitlements
        /v1/subscriptions/{id}/payment_method
        /v1/subscriptions/{id}/upcoming_invoice
      ].sort,
      document.fetch("paths").keys.grep(%r{/v1/subscriptions}).sort
    )
  end

  test "the OpenAPI document declares a POST for every mutating path" do
    document = YAML.load_file(Rails.root.join("openapi/v1.yaml"))

    %w[/v1/subscriptions /v1/subscriptions/{id}/cancel /v1/subscriptions/{id}/change_plan].each do |path|
      assert document.fetch("paths").fetch(path).key?("post"), "#{path} has no POST in openapi/v1.yaml"
    end
  end

  test "every mutating endpoint accepts an Idempotency-Key, in the document and in the code" do
    document = YAML.load_file(Rails.root.join("openapi/v1.yaml"))
    paths = document.fetch("paths").fetch("/v1/subscriptions").fetch("post")
      .fetch("parameters").map { |parameter| parameter["$ref"] }

    assert_includes paths, "#/components/parameters/IdempotencyKey"
  end

  test "the OpenAPI document declares the statuses this controller can answer" do
    document = YAML.load_file(Rails.root.join("openapi/v1.yaml"))
    cancel = document.fetch("paths").fetch("/v1/subscriptions/{id}/cancel").fetch("post").fetch("responses")

    assert_equal %w[200 400 401 404 409 422 503], cancel.keys.sort
  end

  private
    def cancel_path
      "/v1/subscriptions/#{@subscription.id}/cancel"
    end

    def change_plan_path
      "/v1/subscriptions/#{@subscription.id}/change_plan"
    end

    def entitlements_path
      "/v1/subscriptions/#{@subscription.id}/entitlements"
    end

    def downgrade_plan
      @downgrade_plan ||= create_stripe_plan(price: Billing::Money.new(900, "USD"))
    end

    def post_with_key(key, body = {}, to: "/v1/subscriptions")
      post to, params: body, as: :json, headers: { "Idempotency-Key" => key }
    end

    def with_unconfigured_processor
      Processor::StripeClient.current = Processor::StripeClient.new(api_key: nil)
      yield
    ensure
      Processor::StripeClient.current = @processor_under_test
    end

    def create_subscription(plan:, customer: @customer, status: "active")
      Subscription.create!(
        account_id: customer.owner_id,
        customer: customer,
        plan: plan,
        processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1",
        status: status,
        current_period_start: Time.utc(2026, 9, 30, 4, 0, 0),
        current_period_end: Time.utc(2026, 10, 30, 4, 0, 0)
      )
    end
end
