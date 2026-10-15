require "test_helper"

# /v1/subscriptions/:id/upcoming_invoice — the projection, before it is paid.
#
# What the customer will be charged at the renewal, and every figure in it is the
# processor's. The specs here assert what was *asked* of the processor (through
# `FakeStripeAPI`, the same double the client specs use) and what the response
# carries — and the two things the design refuses: a projection of a canceled
# subscription, and any figure this service invented.
class V1UpcomingInvoiceTest < ActionDispatch::IntegrationTest
  ACCOUNT_ID = TestSupport::TestIdentity::Account
  OTHER_OWNER_ID = "22222222-2222-4222-8222-222222222222".freeze
  KNOWN_CUSTOMER_ID = "cus_R1pQKz9xLp2mN4vB6yH8jL0".freeze

  setup do
    travel_to(frozen_now)
    @api = FakeStripeAPI.new
    @previous_processor = Processor::StripeClient.current
    Processor::StripeClient.current = Processor::StripeClient.new(api_key: "sk_test", api: @api)
    @plan = create_stripe_plan(price: Money.new(1900, "USD"))
    @customer = create_stripe_customer(processor_customer_id: KNOWN_CUSTOMER_ID)
    @subscription = create_subscription(plan: @plan, customer: @customer)
  end

  teardown do
    Processor::StripeClient.current = @previous_processor
  end

  # --- the read ---------------------------------------------------------------

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
    # The one figure this service computes: a difference between two of the
    # processor's own figures, for display. Never stored, never sent, never a
    # decision — and the only reason it exists is that a response whose parts do
    # not add up is the worse lie.
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

  # --- the boundary -----------------------------------------------------------

  # Resolved through the same scoped `subscription_record` as every other
  # row-addressed action, so another account's subscription is absent in the same
  # way a uuid naming nothing is — and the processor is not asked.
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

  # A canceled subscription has no upcoming invoice: the processor has stopped
  # collecting, and a projection of a charge that will not happen is a figure
  # this service may not invent. A 409, and it is refused *here* — before the
  # processor is asked a question whose answer would be an error about a
  # subscription this service already knows is canceled.
  test "a canceled subscription is a 409 before the processor is asked" do
    @subscription.update!(status: "canceled")

    get "/v1/subscriptions/#{@subscription.id}/upcoming_invoice"

    assert_response :conflict
    assert_match(/canceled/, json_body.fetch("detail"))
    assert_empty @api.requests
  end

  # The processor said it has no such subscription. The refusal names the field
  # this endpoint's client sent — a `subscription_id`, not the `plan_id` the
  # mutators' client sends — and carries none of the processor's own message.
  test "a processor refusal is a 422 naming the subscription, not the plan" do
    # An id the fake does not know is the processor's own answer, arranged rather
    # than stubbed: `FakeStripeAPI` refuses what Stripe would refuse.
    @subscription.update!(processor_subscription_id: "sub_FAKEunknowndoesnotexist")

    get "/v1/subscriptions/#{@subscription.id}/upcoming_invoice"

    assert_response :unprocessable_entity
    fields = json_body.fetch("errors").map { |error| error.fetch("field") }
    assert_includes fields, "subscription_id"
    refute_includes fields, "plan_id"
    refute_match(/No such subscription/, response.body, "the processor's own message reached the caller")
  end

  # Unconfigured is this service's own misconfiguration, so it is the 503 the
  # mutators give — the caller's request was fine.
  test "an unconfigured processor is a 503" do
    Processor::StripeClient.current = Processor::StripeClient.new(api_key: nil)

    get "/v1/subscriptions/#{@subscription.id}/upcoming_invoice"

    assert_response :service_unavailable
  end

  private
    # The committed fixture's subscription id, resolved to a row this spec owns,
    # so the webhook's payload names a customer and a plan the fixtures know.
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
