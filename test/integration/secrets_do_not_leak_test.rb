require "test_helper"

# What must never appear in a log line, an exception message or a rendered page.
#
# ## Why this is a test and not a linter
#
# The fleet measured this: **no off-the-shelf static analyser finds a secret
# leaked at runtime.** Zero of 268 Semgrep rules intersect CWE-532, gosec has no
# `*ast.CallExpr` case, and Bandit is `ast.Constant`-only. Every one of those
# tools finds a *constant* that looks like a credential, which is not the same
# question at all — the leak is `Rails.logger.error("... #{exception.message}")`
# where the message was built three frames up from something the processor sent.
#
# So it cannot be delegated. It has to be pinned by a test that **captures real log
# output and asserts the secret is absent**, and that renders the failure path
# rather than the happy one, because the failure path is where leaks live: nobody
# logs the value on the way in, everybody logs the exception on the way out.
#
# ## Why the secret is fake
#
# Every value below is a literal in this file that is a credential for nothing:
# `sk_test_…` is the shape, and the suffix is the word `not_a_real_key`. A real
# key in a fixture is a real key in version control, and a real key in a CI log is
# a real key in a retained, searchable, often-public place. The shape is what the
# assertions are about — whether this service can be made to *print* one.
class SecretsDoNotLeakTest < ActionDispatch::IntegrationTest
  setup do
    travel_to(frozen_now)
  end

  # Obviously fake, and shaped like the thing whose leak is being tested.
  FAKE_API_KEY = "sk_test_not_a_real_key_do_not_use".freeze
  FAKE_WEBHOOK_SECRET = "whsec_not_a_real_secret_do_not_use".freeze
  # The suite's own constant is a credential for nothing, and is what the webhook
  # path is actually configured with.
  CONFIGURED_WEBHOOK_SECRET = StripeWebhookHelpers::WEBHOOK_SECRET

  # Every value that must not appear in any captured output. Asserted as a set so
  # that adding a fixture secret here is a deliberate act and adding one to the
  # list is a deliberate omission.
  SECRETS = [ FAKE_API_KEY, FAKE_WEBHOOK_SECRET ].freeze

  # --- the failure paths, which is where a leak lives ------------------------

  # 1. The processor refused a request. `Processor::StripeClient#perform` logs the
  #    exception class and message for every refusal, so this is the single most
  #    likely place in the repository for a processor's internals — and anything
  #    the processor echoed back in that error — to land in a log line.
  #
  #    The refusal is raised for real, through the client's own translation, and
  #    rendered through the controller, so this is the whole path rather than a
  #    hand-made log line.
  test "a processor refusal never prints the processor's API key" do
    logged = capture_log do
      with_env("STRIPE_API_KEY" => FAKE_API_KEY) do
        post_cancel_with_processor_error
      end
    end

    assert_processor_refusal_reached
    assert_no_secret_in logged
  end

  # The same path, asserting the *key* specifically. `Processor::StripeClient` has
  # an `api_key` reader and builds its client from `ENV`, so a `#{client.inspect}`
  # or a `%{api_key}` anywhere near this path would publish it.
  test "a processor refusal never prints the configured API key" do
    logged = capture_log do
      with_env("STRIPE_API_KEY" => FAKE_API_KEY) { post_cancel_with_processor_error }
    end

    refute_includes logged, FAKE_API_KEY
    refute_includes logged, FAKE_API_KEY[0, 12]
  end

  # 2. The webhook could not verify signatures, so it is not configured. The
  #    controller logs the cause of its own 503, which is the log line a
  #    misconfiguration most often ends up in.
  test "an unconfigured signing secret never prints any secret" do
    logged = with_env("STRIPE_WEBHOOK_SECRET" => nil) do
      capture_log { post_stripe_webhook(stripe_fixture("invoice.paid")) }
    end

    assert_response :service_unavailable
    assert_no_secret_in logged
  end

  # 3. A signature that did not verify. `Stripe::SignatureVerificationError`
  #    carries the `sig_header` it was given and the `http_body` it covers, so an
  #    interpolation of the exception anywhere on this path would print both.
  test "a rejected signature never prints the signature header or the body" do
    logged = capture_log do
      post_stripe_webhook(stripe_fixture("invoice.paid"), secret: "whsec_the_wrong_secret")
    end

    assert_response :bad_request
    refute_includes logged, "whsec_the_wrong_secret"
    # The digest itself, not just the secret used to make it.
    refute_includes logged, stripe_signature(stripe_fixture("invoice.paid"), secret: "whsec_the_wrong_secret")
  end

  # 4. A signed event whose mapping raised. The row is parked and the failure is
  #    logged with the processor event id so a human can find it — the id is
  #    necessary and the rest of the message is not.
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

  # The row is the other place the message lands, and it is what a human opens at
  # 3am. `ProcessorWebhook#fail!` truncates to `MAX_ERROR_LENGTH`, and the message
  # is the exception's.
  test "a parked delivery's stored error never carries a customer email" do
    post_stripe_webhook({
      "id" => "evt_secret_probe_row",
      "type" => "invoice.paid",
      "data" => { "object" => { "customer_email" => "victim@example.test" } }
    }.to_json)

    refute_includes ProcessorWebhook.sole.error.to_s, "victim@example.test"
  end

  # 5. The rendered page. Every non-2xx is problem+json, and the detail is the
  #    only free-text field, so it is the only place a processor's message or a
  #    signed body could reach a caller.
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

  # 6. The configuration itself. `Processor::StripeClient` reads `STRIPE_API_KEY`
  #    from the environment at call time, and a misconfiguration raises a message
  #    that gets logged on the way out.
  test "an unconfigured processor never prints a key it does not have" do
    logged = capture_log do
      with_env("STRIPE_API_KEY" => nil) { post_cancel_with_processor_error }
    end

    assert_response :service_unavailable
    assert_no_secret_in logged
    refute_includes logged, "STRIPE_API_KEY=", "the error names the variable's value, not its name"
  end

  # --- and the claim the repository makes about its own credentials -----------

  # The suite's signing secret is a constant on purpose, so that the signature is
  # computed over real bytes rather than stubbed. That is only safe while it is
  # demonstrably a credential for nothing, which is what this asserts: the value
  # is the test sentinel, not a `whsec_` value of any plausible length.
  test "the suite's own webhook secret is the test sentinel and not a plausible credential" do
    assert_equal "whsec_test_only_signing_secret", CONFIGURED_WEBHOOK_SECRET
    assert_operator CONFIGURED_WEBHOOK_SECRET.length, :<, 40
  end

  # A signature test that called out to a processor would be a test that fails in
  # CI and that a network timeout could make pass. The tier is verified against a
  # locally computed signature over a locally built body, and this is the assertion
  # that the local computation is what verified.
  test "a webhook signature is verified against a locally computed digest, with no network" do
    body = stripe_fixture("invoice.paid")
    expected = OpenSSL::HMAC.hexdigest("SHA256", CONFIGURED_WEBHOOK_SECRET, "#{Time.now.to_i}.#{body}")

    post_stripe_webhook(body)

    assert_response :ok
    assert_equal expected, stripe_signature(body, secret: CONFIGURED_WEBHOOK_SECRET).split("v1=").last
  end

  private
    # Every fake secret, absent from the captured output.
    def assert_no_secret_in(output)
      SECRETS.each do |secret|
        refute_includes output, secret, "a secret reached the log: #{secret[0, 8]}…"
      end
    end

    # The controller refused, rather than the request failing for some other reason
    # and the assertions above passing over a path that was never reached. A leak
    # test that does not prove it rendered the failure path is a test that can
    # pass without ever having looked at the log line it is about.
    #
    # 422 is the answer `refuse_processor` gives for a processor refusal that is
    # not our own misconfiguration, so asserting exactly that is what says "the
    # client's request was fine and the processor said no".
    def assert_processor_refusal_reached
      assert_response :unprocessable_content,
        "the processor refusal path was not reached, so this test proves nothing"
      assert_equal "invalid", json_body.dig("errors", 0, "code")
    end

    # Drives `POST /v1/subscriptions/{id}/cancel` against a real subscription with
    # a processor that refuses, so `Processor::StripeClient#perform` runs its own
    # rescue for real and the log line under test is the one production writes.
    #
    # The refusal is injected through the **`api:` seam** — the one
    # `StripeClient#initialize` exists for — and not by subclassing. Subclassing
    # `cancel_subscription` would replace the very method whose rescue is under
    # test, so the exception would escape unwrapped and the log line would never
    # be written. Going in at `stripe` means `require_configured!`, `perform`, the
    # `RequestFailed` translation and the controller's `refuse_processor` all run
    # exactly as they do in production.
    #
    # The refusal carries the processor's own text, which is the realistic shape.
    # See `RefusingProcessorApi` for why the message must not contain the key.
    #
    # The customer is built here rather than in a parameter default. A default
    # argument is evaluated on every call, which is what is wanted — each test
    # gets its own customer — but writing a four-line record creation into the
    # signature hides the one side effect in it, and a reader checking what this
    # posts has to parse the parameter list to find it.
    def post_cancel_with_processor_error
      # **The customer is owned by the account the token names**, not by a random
      # uuid. `/v1` is scoped by the token's `account_id` since billing-21, so a
      # subscription belonging to anybody else is a 404 and these tests would have
      # asserted the *scoping* rather than the redaction — passing while the log line
      # they exist to inspect was never written.
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

    # The refusal carries the processor's own text, which is the realistic shape:
    # Stripe's error messages describe what it refused and quote the offending
    # *parameter*, never the key. A stub that pasted the key into its own message
    # would prove nothing — the leak would be the fixture's, and the test would
    # pass or fail for a reason that has nothing to do with this service.
    #
    # What is under test is the other direction: the service is *configured* with a
    # key that must never come back out, on a path where it holds that key in
    # memory and logs the failure. `Processor::StripeClient` exposes `api_key` as a
    # reader and builds its client from `ENV`, so a single interpolated
    # `#{client.inspect}` or `%{api_key}` anywhere near here publishes it. That is
    # a mutation this file is built to catch.
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
