require "test_helper"

# The only place this service talks *to* Stripe.
#
# Two things this seam is for, and they are different:
#
#   * **It is the whole of the outbound surface.** Every Stripe call in this
#     repository is one of these four methods. That is what makes "this service
#     only receives from Stripe" a claim about the code rather than an intention:
#     there is no `Stripe::` call anywhere else to find. The fourth — the
#     upcoming invoice — is the first one that *receives* rather than sends, and
#     it is held to the same shape: two of the processor's own ids go out, and
#     every figure that comes back is the processor's.
#   * **It is the seam the specs replace.** A checkout URL and a subscription's
#     existence both come from Stripe, so a test cannot invent them and assert
#     the invention. The specs record what was *asked* of Stripe and assert on the
#     request; the response is a fixture of the processor's, not of this service's
#     design.
#
# What the client deliberately does **not** do is compute anything about money.
# `apply_plan_change` sends a `proration_behavior`; the amount that behaviour
# produces is Stripe's. `create_checkout_session` sends a price id.
# `cancel_subscription` sends an id and a boolean. A figure calculated in Ruby and
# sent to Stripe would be a figure that eventually disagreed with the processor's
# ledger, and the disagreement would surface in a customer's invoice.
class Processor::StripeClientTest < ActiveSupport::TestCase
  setup do
    travel_to(frozen_now)
    @api = FakeStripeAPI.new
  end

  # --- configuration ----------------------------------------------------------

  test "a client with no api key refuses to send a request" do
    client = Processor::StripeClient.new(api_key: nil)

    assert_raises(Processor::StripeClient::Unconfigured) { client.create_checkout_session(**checkout_params) }
  end

  test "a blank api key is refused" do
    client = Processor::StripeClient.new(api_key: "  ")

    assert_raises(Processor::StripeClient::Unconfigured) { client.create_checkout_session(**checkout_params) }
  end

  # The variable, not the value. An operator who reads this knows what to set; an
  # operator given the value already has it.
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

  # --- checkout sessions ------------------------------------------------------

  test "a checkout session is created in subscription mode, because that is what a plan is" do
    client_for(@api).create_checkout_session(**checkout_params)

    assert_equal "subscription", @api.requests.sole.fetch(:mode)
  end

  test "a checkout session is created for one plan at its processor price" do
    client_for(@api).create_checkout_session(**checkout_params)

    assert_equal [ { price: "price_1PZQaBcDeFgHiJkLmNoPqR2", quantity: 1 } ], @api.requests.sole.fetch(:line_items)
  end

  # The reference is how a later webhook is tied back to a cafaye customer, and it
  # is cafaye's own id rather than the processor's: `customers.processor_customer_id`
  # is null for every customer in v0, so the processor has no id of ours to match on
  # at this point and the subscription's metadata is the only thing that can carry
  # the link. The resolution itself lives in Subscriptions::Lifecycle.
  test "a checkout session carries this service's own customer id in the subscription's metadata" do
    client_for(@api).create_checkout_session(**checkout_params)

    metadata = @api.requests.sole.fetch(:subscription_data).fetch(:metadata)
    assert_equal "11111111-1111-4111-8111-111111111111", metadata.fetch(:cafaye_customer_id)
  end

  test "a checkout session also carries it as the reference the processor echoes back" do
    client_for(@api).create_checkout_session(**checkout_params)

    assert_equal "11111111-1111-4111-8111-111111111111", @api.requests.sole.fetch(:client_reference_id)
  end

  test "a checkout session with no customer reference says it is empty, not that it is absent" do
    client_for(@api).create_checkout_session(**checkout_params(customer_reference: nil))

    assert_nil @api.requests.sole.fetch(:subscription_data).fetch(:metadata).fetch(:cafaye_customer_id)
  end

  test "a checkout session tells the processor which customer to charge, when we know their processor id" do
    client_for(@api).create_checkout_session(**checkout_params(processor_customer_id: "cus_R1pQKz9xLp2mN4vB6yH8jL0"))

    assert_equal "cus_R1pQKz9xLp2mN4vB6yH8jL0", @api.requests.sole.fetch(:customer)
  end

  # A customer whose processor id we do not have is normal in v0, not an error:
  # every customer created through /v1 has a null `processor_customer_id`. Sending
  # nil lets the processor create the customer and tell us about it in the
  # subscription that comes back.
  test "a checkout session for a customer with no processor id asks the processor to create one" do
    client_for(@api).create_checkout_session(**checkout_params(processor_customer_id: nil))

    assert_nil @api.requests.sole.fetch(:customer)
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

  # --- plan changes -----------------------------------------------------------

  test "a plan change is applied to the processor's own subscription" do
    client_for(@api).apply_plan_change(processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1", price_id: "price_new")

    assert_equal "sub_1PZQaBcDeFgHiJkLmNoPqR1", @api.requests.sole.fetch(:id)
  end

  test "a plan change moves the subscription onto the new processor price" do
    client_for(@api).apply_plan_change(processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1", price_id: "price_new")

    assert_equal [ "price_new" ], @api.requests.sole.fetch(:items)
  end

  # The whole point of the seam: a behaviour goes out, never a figure. These three
  # absences are the assertion that no proration arithmetic has crept in here.
  test "a plan change tells the processor how to treat the difference, and never says what it is" do
    client_for(@api).apply_plan_change(
      processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1",
      price_id: "price_new",
      proration_behavior: Subscriptions::PlanChange::ALWAYS_INVOICE
    )

    request = @api.requests.sole
    assert_equal "always_invoice", request.fetch(:proration_behavior)
    refute request.key?(:amount)
    refute request.key?(:credit)
    refute request.key?(:refund)
  end

  # The key is absent rather than nil. `proration_behavior: nil` is a value the
  # processor would have to interpret, and an absent key is the one thing whose
  # meaning is already agreed.
  test "a plan change with no proration behaviour sends no key at all" do
    client_for(@api).apply_plan_change(processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1", price_id: "price_new")

    refute_includes @api.requests.sole.keys, :proration_behavior
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

  # --- cancellation -----------------------------------------------------------

  test "a cancellation names the processor's own subscription" do
    client_for(@api).cancel_subscription(processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1", at_period_end: true)

    assert_equal "sub_1PZQaBcDeFgHiJkLmNoPqR1", @api.requests.sole.fetch(:id)
  end

  test "a cancellation at period end says so to the processor" do
    client_for(@api).cancel_subscription(processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1", at_period_end: true)

    assert_equal true, @api.requests.sole.fetch(:cancel_at_period_end)
  end

  test "a cancellation now does not say to keep it to the period end" do
    client_for(@api).cancel_subscription(processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1", at_period_end: false)

    assert_equal false, @api.requests.sole.fetch(:cancel_at_period_end)
  end

  # A cancellation is the one place a service is most tempted to compute a refund
  # — "they paid for three weeks we are taking away". Not here. The processor owns
  # that number, and a refund this service invented would be a number it did not
  # keep.
  test "a cancellation asks for no refund and no proration, because this service computes neither" do
    client_for(@api).cancel_subscription(processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1", at_period_end: false)

    request = @api.requests.sole
    refute request.key?(:refund)
    refute request.key?(:prorate)
    refute request.key?(:amount)
  end

  test "a cancellation returns the processor's own subscription" do
    result = client_for(@api).cancel_subscription(processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1", at_period_end: true)

    assert_equal "sub_1PZQaBcDeFgHiJkLmNoPqR1", result.id
  end

  # --- the upcoming invoice ---------------------------------------------------

  # The projection: what the customer will be charged at the renewal, before it
  # is paid. Two of the processor's own ids go out — the subscription and the
  # customer it is billed to — and the request is recorded like every other.
  test "an upcoming invoice names the subscription and the customer it belongs to" do
    client_for(@api).upcoming_invoice(
      processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1",
      processor_customer_id: "cus_R1pQKz9xLp2mN4vB6yH8jL0"
    )

    request = @api.requests.sole
    assert_equal "sub_1PZQaBcDeFgHiJkLmNoPqR1", request.fetch(:subscription)
    assert_equal "cus_R1pQKz9xLp2mN4vB6yH8jL0", request.fetch(:customer)
  end

  # No amount is computed here and none is sent: the projection is a *read*.
  # This is the assertion that a future edit which "helpfully" adds a computed
  # figure to the request fails by name.
  test "an upcoming invoice asks for no amount, because it is a read" do
    client_for(@api).upcoming_invoice(
      processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1",
      processor_customer_id: "cus_R1pQKz9xLp2mN4vB6yH8jL0"
    )

    request = @api.requests.sole
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
    assert_equal 1900, line.price.unit_amount
    assert_equal 1900, line.amount
    assert_equal 1, line.quantity
  end

  # --- what a processor can refuse --------------------------------------------

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
        processor_customer_id: nil
      }.merge(overrides)
    end
end
