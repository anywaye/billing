require "test_helper"

class SecretsDoNotLeakTest < ActionDispatch::IntegrationTest
  setup do
    travel_to(frozen_now)
  end

  FAKE_API_KEY = "sk_test_not_a_real_key_do_not_use".freeze
  FAKE_WEBHOOK_SECRET = "whsec_not_a_real_secret_do_not_use".freeze
  CONFIGURED_WEBHOOK_SECRET = StripeWebhookHelpers::WEBHOOK_SECRET

  SECRETS = [ FAKE_API_KEY, FAKE_WEBHOOK_SECRET ].freeze


  test "a processor refusal never prints the processor's API key" do
    logged = capture_log do
      with_env("STRIPE_API_KEY" => FAKE_API_KEY) do
        post_cancel_with_processor_error
      end
    end

    assert_processor_refusal_reached
    assert_no_secret_in logged
  end

  test "a processor refusal never prints the configured API key" do
    logged = capture_log do
      with_env("STRIPE_API_KEY" => FAKE_API_KEY) { post_cancel_with_processor_error }
    end

    refute_includes logged, FAKE_API_KEY
    refute_includes logged, FAKE_API_KEY[0, 12]
  end

  test "an unconfigured signing secret never prints any secret" do
    logged = with_env("STRIPE_WEBHOOK_SECRET" => nil) do
      capture_log { post_stripe_webhook(stripe_fixture("invoice.paid")) }
    end

    assert_response :service_unavailable
    assert_no_secret_in logged
  end

  test "a rejected signature never prints the signature header or the body" do
    logged = capture_log do
      post_stripe_webhook(stripe_fixture("invoice.paid"), secret: "whsec_the_wrong_secret")
    end

    assert_response :bad_request
    refute_includes logged, "whsec_the_wrong_secret"
    refute_includes logged, stripe_signature(stripe_fixture("invoice.paid"), secret: "whsec_the_wrong_secret")
  end

  test "a parked delivery never prints a customer email into the log" do
    logged = capture_log do
      post_stripe_webhook({
        "id" => "evt_secret_probe",
        "type" => "invoice.paid",
        "data" => { "object" => { "customer_email" => "victim@example.test" } }
      }.to_json)
    end

    assert_response :ok
    refute_includes logged, "victim@example.test"
  end

  test "a parked delivery's stored error never carries a customer email" do
    post_stripe_webhook({
      "id" => "evt_secret_probe_row",
      "type" => "invoice.paid",
      "data" => { "object" => { "customer_email" => "victim@example.test" } }
    }.to_json)

    refute_includes ProcessorWebhook.sole.error.to_s, "victim@example.test"
  end

  test "no problem body on the webhook path ever echoes the request body" do
    body = { "id" => "evt_echo", "type" => "invoice.paid", "data" => { "object" => {} },
             "customer_email" => "victim@example.test" }.to_json

    capture_log { post_stripe_webhook(body) }

    refute_includes response.body, "victim@example.test"
    refute_includes response.body, body
  end

  test "a processor refusal's problem body never carries the processor's own text" do
    with_env("STRIPE_API_KEY" => FAKE_API_KEY) { post_cancel_with_processor_error }

    assert_response :unprocessable_content
    refute_includes response.body, "No such subscription"
    refute_includes response.body, FAKE_API_KEY
  end

  test "an unconfigured processor never prints a key it does not have" do
    logged = capture_log do
      with_env("STRIPE_API_KEY" => nil) { post_cancel_with_processor_error }
    end

    assert_response :service_unavailable
    assert_no_secret_in logged
    refute_includes logged, "STRIPE_API_KEY=", "the error names the variable's value, not its name"
  end


  test "the suite's own webhook secret is the test sentinel and not a plausible credential" do
    assert_equal "whsec_test_only_signing_secret", CONFIGURED_WEBHOOK_SECRET
    assert_operator CONFIGURED_WEBHOOK_SECRET.length, :<, 40
  end

  test "a webhook signature is verified against a locally computed digest, with no network" do
    body = stripe_fixture("invoice.paid")
    expected = OpenSSL::HMAC.hexdigest("SHA256", CONFIGURED_WEBHOOK_SECRET, "#{Time.now.to_i}.#{body}")

    post_stripe_webhook(body)

    assert_response :ok
    assert_equal expected, stripe_signature(body, secret: CONFIGURED_WEBHOOK_SECRET).split("v1=").last
  end

  private
    def assert_no_secret_in(output)
      SECRETS.each do |secret|
        refute_includes output, secret, "a secret reached the log: #{secret[0, 8]}…"
      end
    end

    def assert_processor_refusal_reached
      assert_response :unprocessable_content,
        "the processor refusal path was not reached, so this test proves nothing"
      assert_equal "invalid", json_body.dig("errors", 0, "code")
    end

    def post_cancel_with_processor_error
      customer = Customer.create!(
        owner_type: "Account", owner_id: TestSupport::TestIdentity::Account,
        processor: "stripe", processor_customer_id: "cus_secret_probe"
      )
      plan = Plan.create!(
        name: "Secret probe", slug: "secret-probe-#{SecureRandom.hex(3)}",
        price: Billing::Money.new(1900, "USD"), interval: "month",
        processor_price_id: "price_secret_probe"
      )
      subscription = Subscription.create!(
        account_id: customer.owner_id, customer: customer, plan: plan,
        processor_subscription_id: "sub_secret_probe", status: "active"
      )

      Processor::StripeClient.current = Processor::StripeClient.new(
        api_key: ENV["STRIPE_API_KEY"], api: RefusingProcessorApi.new
      )
      post "/v1/subscriptions/#{subscription.id}/cancel",
        params: { at_period_end: false }.to_json,
        headers: { "CONTENT_TYPE" => "application/json" }
    ensure
      Processor::StripeClient.current = nil
    end

    class RefusingProcessorApi
      def update_subscription(id, params)
        raise Stripe::StripeError.new(
          "No such subscription: #{id} (cancel_at_period_end=#{params[:cancel_at_period_end]})"
        )
      end

      def create_checkout_session(_params) = raise("this test must not create a checkout")

      def cancel_subscription(*_args) = raise("this test must not reach the adapter's cancel")
    end
end
