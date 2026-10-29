require "test_helper"

class Processor::StripeClientTest < ActiveSupport::TestCase
  setup do
    travel_to(frozen_now)
    @api = FakeStripeAPI.new
  end


  test "a client with no api key refuses to send a request" do
    client = Processor::StripeClient.new(api_key: nil)

    assert_raises(Processor::StripeClient::Unconfigured) { client.create_checkout_session(**checkout_params) }
  end

  test "a blank api key is refused" do
    client = Processor::StripeClient.new(api_key: "  ")

    assert_raises(Processor::StripeClient::Unconfigured) { client.create_checkout_session(**checkout_params) }
  end

  test "the refusal names the variable, so an operator knows what to set" do
    client = Processor::StripeClient.new(api_key: nil)

    error = assert_raises(Processor::StripeClient::Unconfigured) { client.create_checkout_session(**checkout_params) }
    assert_match(/STRIPE_API_KEY/, error.message)
  end

  test "a client reads its key from the environment when it is given none" do
    with_env("STRIPE_API_KEY" => "sk_from_the_environment") do
      assert_equal "sk_from_the_environment", Processor::StripeClient.new.api_key
    end
  end

  test "an explicitly supplied key beats the environment" do
    with_env("STRIPE_API_KEY" => "sk_from_the_environment") do
      assert_equal "sk_supplied", Processor::StripeClient.new(api_key: "sk_supplied").api_key
    end
  end

  test "a client with no key reports the key as absent rather than as empty" do
    with_env("STRIPE_API_KEY" => nil) do
      assert_nil Processor::StripeClient.new.api_key
    end
  end

  test "an unauthenticated request is refused without putting anything key-shaped in the log" do
    logged = capture_log do
      with_env("STRIPE_API_KEY" => nil) do
        assert_raises(Processor::StripeClient::Unconfigured) { Processor::StripeClient.new.create_checkout_session(**checkout_params) }
      end
    end

    refute_match(/sk_/, logged)
  end

  test "every method refuses without a key, not only the first one to be called" do
    client = Processor::StripeClient.new(api_key: nil)

    assert_raises(Processor::StripeClient::Unconfigured) { client.apply_plan_change(processor_subscription_id: "sub_1", price_id: "price_1") }
    assert_raises(Processor::StripeClient::Unconfigured) { client.cancel_subscription(processor_subscription_id: "sub_1", at_period_end: true) }
  end


  test "a checkout session is created in subscription mode, because that is what a plan is" do
    client_for(@api).create_checkout_session(**checkout_params)

    assert_equal "subscription", @api.requests.last.fetch(:mode)
  end

  test "a checkout session is created for one plan at its processor price" do
    client_for(@api).create_checkout_session(**checkout_params)

    assert_equal [ { price: "price_1PZQaBcDeFgHiJkLmNoPqR2", quantity: 1 } ], @api.requests.last.fetch(:line_items)
  end

  test "a checkout session carries this service's own customer id in the subscription's metadata" do
    client_for(@api).create_checkout_session(**checkout_params)

    metadata = @api.requests.last.fetch(:subscription_data).fetch(:metadata)
    assert_equal "11111111-1111-4111-8111-111111111111", metadata.fetch(:anywaye_customer_id)
  end

  test "a checkout session also carries it as the reference the processor echoes back" do
    client_for(@api).create_checkout_session(**checkout_params)

    assert_equal "11111111-1111-4111-8111-111111111111", @api.requests.last.fetch(:client_reference_id)
  end

  test "a checkout session with no customer reference says it is empty, not that it is absent" do
    client_for(@api).create_checkout_session(**checkout_params(customer_reference: nil))

    assert_nil @api.requests.last.fetch(:subscription_data).fetch(:metadata).fetch(:anywaye_customer_id)
  end

  test "a checkout session tells the processor which customer to charge, when we know their processor id" do
    client_for(@api).create_checkout_session(**checkout_params(processor_customer_id: "cus_R1pQKz9xLp2mN4vB6yH8jL0"))

    assert_equal "cus_R1pQKz9xLp2mN4vB6yH8jL0", @api.requests.last.fetch(:customer)
  end

  test "a checkout session for a customer with no processor id asks the processor to create one" do
    client_for(@api).create_checkout_session(**checkout_params(processor_customer_id: nil))

    assert_nil @api.requests.last.fetch(:customer)
  end

  test "a checkout session returns the processor's own session id" do
    session = client_for(@api).create_checkout_session(**checkout_params)

    assert_equal "cs_test_00000000000001", session.id
  end

  test "a checkout session returns the processor's own url, not one this service built" do
    session = client_for(@api).create_checkout_session(**checkout_params)

    assert_equal "https://checkout.stripe.test/c/pay/cs_test_00000000000001", session.url
  end

  test "a checkout session makes exactly one request" do
    client_for(@api).create_checkout_session(**checkout_params)

    assert_equal 1, @api.requests.size
  end

  test "a checkout session with no processor id for the plan is refused before the request" do
    client = client_for(@api)

    assert_raises(Processor::StripeClient::Unpriced) { client.create_checkout_session(**checkout_params(plan_price_id: nil)) }
    assert_empty @api.requests
  end


  test "a plan change is applied to the processor's own subscription" do
    client_for(@api).apply_plan_change(processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1", price_id: "price_new")

    assert_equal "sub_1PZQaBcDeFgHiJkLmNoPqR1", @api.requests.last.fetch(:id)
  end

  test "a plan change moves the subscription onto the new processor price" do
    client_for(@api).apply_plan_change(processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1", price_id: "price_new")

    update = @api.requests.last
    assert_equal [ { id: "si_FAKE1PZQaBcDeFgHiJkLmNoPqR1", price: "price_new" } ], update.fetch(:items)
  end

  test "a plan change tells the processor how to treat the difference, and never says what it is" do
    client_for(@api).apply_plan_change(
      processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1",
      price_id: "price_new",
      proration_behavior: Subscriptions::PlanChange::ALWAYS_INVOICE
    )

    request = @api.requests.last
    assert_equal "always_invoice", request.fetch(:proration_behavior)
    refute request.key?(:amount)
    refute request.key?(:credit)
    refute request.key?(:refund)
  end

  test "a plan change with no proration behaviour sends no key at all" do
    client_for(@api).apply_plan_change(processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1", price_id: "price_new")

    refute_includes @api.requests.last.keys, :proration_behavior
  end

  test "a plan change returns the processor's own subscription" do
    result = client_for(@api).apply_plan_change(processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1", price_id: "price_new")

    assert_equal "sub_1PZQaBcDeFgHiJkLmNoPqR1", result.id
  end

  test "a plan change with no processor id for the new plan is refused before the request" do
    client = client_for(@api)

    assert_raises(Processor::StripeClient::Unpriced) do
      client.apply_plan_change(processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1", price_id: nil)
    end
    assert_empty @api.requests
  end


  test "a cancellation names the processor's own subscription" do
    client_for(@api).cancel_subscription(processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1", at_period_end: true)

    assert_equal "sub_1PZQaBcDeFgHiJkLmNoPqR1", @api.requests.last.fetch(:id)
  end

  test "a cancellation at period end says so to the processor" do
    client_for(@api).cancel_subscription(processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1", at_period_end: true)

    assert_equal true, @api.requests.last.fetch(:cancel_at_period_end)
  end

  test "a cancellation now does not say to keep it to the period end" do
    client_for(@api).cancel_subscription(processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1", at_period_end: false)

    assert_equal false, @api.requests.last.fetch(:cancel_at_period_end)
  end

  test "a cancellation asks for no refund and no proration, because this service computes neither" do
    client_for(@api).cancel_subscription(processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1", at_period_end: false)

    request = @api.requests.last
    refute request.key?(:refund)
    refute request.key?(:prorate)
    refute request.key?(:amount)
  end

  test "a cancellation returns the processor's own subscription" do
    result = client_for(@api).cancel_subscription(processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1", at_period_end: true)

    assert_equal "sub_1PZQaBcDeFgHiJkLmNoPqR1", result.id
  end


  test "an upcoming invoice names the subscription and the customer it belongs to" do
    client_for(@api).upcoming_invoice(
      processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1",
      processor_customer_id: "cus_R1pQKz9xLp2mN4vB6yH8jL0"
    )

    request = @api.requests.last
    assert_equal "sub_1PZQaBcDeFgHiJkLmNoPqR1", request.fetch(:subscription)
    assert_equal "cus_R1pQKz9xLp2mN4vB6yH8jL0", request.fetch(:customer)
  end

  test "an upcoming invoice asks for no amount, because it is a read" do
    client_for(@api).upcoming_invoice(
      processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1",
      processor_customer_id: "cus_R1pQKz9xLp2mN4vB6yH8jL0"
    )

    request = @api.requests.last
    assert_empty request.keys - %i[subscription customer],
      "the projection sent something other than the two identifiers: #{request.keys.inspect}"
  end

  test "an upcoming invoice returns the processor's own projection untouched" do
    invoice = client_for(@api).upcoming_invoice(
      processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1",
      processor_customer_id: "cus_R1pQKz9xLp2mN4vB6yH8jL0"
    )

    assert_equal "usd", invoice.currency
    assert_equal 1900, invoice.subtotal
    assert_equal 1900, invoice.total_excluding_tax
    assert_equal 2147, invoice.total
    assert_equal 1, invoice.lines.size
    line = invoice.lines.first
    assert_equal "Pro monthly", line.description
    assert_equal 1900, BigDecimal(line.pricing.unit_amount_decimal.to_s).to_i
    assert_equal 1900, line.amount
    assert_equal 1, line.quantity
  end


  test "a processor refusal is this service's own class, so a caller need not rescue the gem's" do
    client = client_for(@api)

    assert_raises(Processor::StripeClient::RequestFailed) do
      client.cancel_subscription(processor_subscription_id: "sub_unknown", at_period_end: true)
    end
  end

  test "a refusal carries the processor's own message rather than a sentence this service invented" do
    client = client_for(@api)

    error = assert_raises(Processor::StripeClient::RequestFailed) do
      client.cancel_subscription(processor_subscription_id: "sub_unknown", at_period_end: true)
    end
    assert_match(/No such subscription/, error.message)
  end

  test "a refusal names the subscription that could not be changed, so the row is findable" do
    client = client_for(@api)

    error = assert_raises(Processor::StripeClient::RequestFailed) do
      client.cancel_subscription(processor_subscription_id: "sub_unknown", at_period_end: true)
    end
    assert_match(/sub_unknown/, error.message)
  end

  test "a checkout refusal is the same class as any other processor refusal" do
    client = client_for(@api)

    assert_raises(Processor::StripeClient::RequestFailed) { client.create_checkout_session(**checkout_params(plan_price_id: "price_gone")) }
  end

  test "a plan change refusal is the same class as any other processor refusal" do
    client = client_for(@api)

    assert_raises(Processor::StripeClient::RequestFailed) do
      client.apply_plan_change(processor_subscription_id: "sub_unknown", price_id: "price_new")
    end
  end

  test "a refusal is logged with its cause, because the body a caller gets will not carry it" do
    client = client_for(@api)

    logged = capture_log do
      assert_raises(Processor::StripeClient::RequestFailed) do
        client.apply_plan_change(processor_subscription_id: "sub_unknown", price_id: "price_new")
      end
    end

    assert_includes logged, "sub_unknown"
  end

  private
    def client_for(api)
      @client_for ||= {}
      @client_for[api] ||= Processor::StripeClient.new(api_key: "sk_test", api: api)
    end

    def checkout_params(overrides = {})
      {
        plan_price_id: "price_1PZQaBcDeFgHiJkLmNoPqR2",
        customer_reference: "11111111-1111-4111-8111-111111111111",
        success_url: "https://app.anywaye.com/billing",
        processor_customer_id: nil
      }.merge(overrides)
    end
end
