require "test_helper"

class V1UpcomingInvoiceTest < ActionDispatch::IntegrationTest
  ACCOUNT_ID = TestSupport::TestIdentity::Account
  OTHER_OWNER_ID = "22222222-2222-4222-8222-222222222222".freeze
  KNOWN_CUSTOMER_ID = "cus_R1pQKz9xLp2mN4vB6yH8jL0".freeze

  setup do
    travel_to(frozen_now)
    @api = FakeStripeAPI.new
    @previous_processor = Processor::StripeClient.current
    Processor::StripeClient.current = Processor::StripeClient.new(api_key: "sk_test", api: @api)
    @plan = create_stripe_plan(price: Billing::Money.new(1900, "USD"))
    @customer = create_stripe_customer(processor_customer_id: KNOWN_CUSTOMER_ID)
    @subscription = create_subscription(plan: @plan, customer: @customer)
  end

  teardown do
    Processor::StripeClient.current = @previous_processor
  end


  test "GET /v1/subscriptions/:id/upcoming_invoice asks the processor about this subscription" do
    get "/v1/subscriptions/#{@subscription.id}/upcoming_invoice"

    assert_response :ok
    request = @api.requests.sole
    assert_equal @subscription.processor_subscription_id, request.fetch(:subscription)
    assert_equal KNOWN_CUSTOMER_ID, request.fetch(:customer)
    assert_equal 2, request.keys.size, "the projection sent something other than the two identifiers"
  end

  test "the response carries the processor's figures in minor units" do
    get "/v1/subscriptions/#{@subscription.id}/upcoming_invoice"

    body = json_body
    assert_equal @subscription.id, body.fetch("subscription_id")
    assert_equal "USD", body.fetch("currency")
    assert_equal 1900, body.fetch("subtotal")
    assert_equal 2147, body.fetch("total")
    assert_equal 247, body.fetch("tax")
    assert_equal body.fetch("subtotal") + body.fetch("tax"), body.fetch("total")
  end

  test "a line item carries the processor's own unit amount, not a derived one" do
    get "/v1/subscriptions/#{@subscription.id}/upcoming_invoice"

    line = json_body.fetch("line_items").sole
    assert_equal "Pro monthly", line.fetch("description")
    assert_equal 1900, line.fetch("unit_amount")
    assert_equal 1900, line.fetch("amount")
    assert_equal 1, line.fetch("quantity")
    assert_equal({ "start" => Time.at(frozen_now.to_i).utc.iso8601, "end" => Time.at(frozen_now.to_i + 30 * 24 * 60 * 60).utc.iso8601 },
      line.fetch("period"))
  end


  test "another account's subscription is a 404 and the processor is never asked" do
    other_customer = create_stripe_customer(account_id: OTHER_OWNER_ID)
    other_subscription = create_subscription(
      plan: @plan,
      customer: other_customer,
      processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR9"
    )

    get "/v1/subscriptions/#{other_subscription.id}/upcoming_invoice"

    assert_response :not_found
    assert_empty @api.requests
  end

  test "a canceled subscription is a 409 before the processor is asked" do
    @subscription.update!(status: "canceled")

    get "/v1/subscriptions/#{@subscription.id}/upcoming_invoice"

    assert_response :conflict
    assert_match(/canceled/, json_body.fetch("detail"))
    assert_empty @api.requests
  end

  test "a processor refusal is a 422 naming the subscription, not the plan" do
    @subscription.update!(processor_subscription_id: "sub_STRIPEunknowndoesnotexist")

    get "/v1/subscriptions/#{@subscription.id}/upcoming_invoice"

    assert_response :unprocessable_entity
    fields = json_body.fetch("errors").map { |error| error.fetch("field") }
    assert_includes fields, "subscription_id"
    refute_includes fields, "plan_id"
    refute_match(/No such subscription/, response.body, "the processor's own message reached the caller")
  end

  test "an unconfigured processor is a 503" do
    Processor::StripeClient.current = Processor::StripeClient.new(api_key: nil)

    get "/v1/subscriptions/#{@subscription.id}/upcoming_invoice"

    assert_response :service_unavailable
  end

  private
    def create_subscription(plan:, customer:, processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1")
      Subscription.create!(
        account_id: customer.owner_id,
        customer: customer,
        plan: plan,
        processor_subscription_id: processor_subscription_id,
        status: "active"
      )
    end
end
