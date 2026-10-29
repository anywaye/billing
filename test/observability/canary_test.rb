require "test_helper"

class ObservabilityCanaryTest < ActionDispatch::IntegrationTest
  CANARY = "CANARY-4e1b-DO-NOT-EXPORT"

  setup do
    travel_to(frozen_now)
    TestSupport::TestSpanExporter.clear!
  end

  teardown do
    TestSupport::TestSpanExporter.clear!
  end


  test "a customer with an email and a processor id exports neither" do
    post "/v1/customers", params: {
      customer: {
        email: "#{CANARY}@example.com",
        processor_customer_id: "cus_#{CANARY}"
      }
    }

    assert_includes [ 201, 422 ], response.status
    assert_no_canary
  end

  test "a plan carrying a price and a slug exports neither" do
    post "/v1/plans", params: {
      plan: { name: CANARY, slug: "plan-#{CANARY}", price: "10.00", currency: "USD", interval: "month" }
    }

    assert_includes [ 201, 422 ], response.status
    assert_no_canary
  end

  test "a subscription addressed by a customer id in the path exports neither id" do
    customer = Customer.create!(owner_type: "Account", owner_id: SecureRandom.uuid,
                                processor: "stripe",
                                processor_customer_id: "cus_FAKE#{SecureRandom.hex(8)}")

    get "/v1/subscriptions/#{customer.id}/entitlements"

    assert_includes [ 200, 404 ], response.status
    assert_no_canary
  end


  test "an id in the PATH of a parameterised route reaches nothing" do
    get "/v1/customers/#{CANARY}"

    assert_response :not_found
    assert_no_canary
  end

  test "a slug in the PATH reaches nothing" do
    get "/v1/plans/#{CANARY}"

    assert_response :not_found
    assert_no_canary
  end


  test "an email in the query string of a matched route reaches nothing" do
    get "/v1/customers", params: { email: "#{CANARY}@example.com", owner_id: CANARY }

    assert_includes [ 200, 400 ], response.status
    assert_no_canary
  end


  test "a bearer token, an API key, a cookie and a user-agent are all absent" do
    get "/healthz", headers: {
      "HTTP_AUTHORIZATION" => "Bearer sess_#{CANARY}",
      "HTTP_COOKIE" => "billing_session=#{CANARY}",
      "HTTP_X_API_KEY" => "caf_#{CANARY}",
      "HTTP_USER_AGENT" => "canary-agent/#{CANARY}",
      "HTTP_IDEMPOTENCY_KEY" => "9f8e7d6c-#{CANARY}"
    }

    assert_response :success
    assert_no_canary
  end


  test "a signed webhook body exports neither the payload nor the signature" do
    payload = {
      id: "evt_#{CANARY}",
      type: "customer.subscription.updated",
      data: { object: { id: "cus_#{CANARY}", email: "#{CANARY}@example.com" } }
    }.to_json
    timestamp = Time.now.to_i

    post StripeWebhookHelpers::STRIPE_WEBHOOK_PATH,
         params: payload,
         headers: {
           "CONTENT_TYPE" => "application/json"
         }

    assert_includes [ 200, 400, 503 ], response.status
    assert_no_canary
  end


  test "a malformed traceparent carrying content is IGNORED, not recorded" do
    get "/healthz", headers: { "HTTP_TRACEPARENT" => "00-#{CANARY}-#{CANARY}-01" }

    assert_response :success
    assert_no_canary
  end

  test "a well-formed inbound traceparent links the spans without copying its header" do
    get "/healthz", headers: {
      "HTTP_TRACEPARENT" => "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    }

    assert_response :success
    span = TestSupport::TestSpans.request_spans.first
    assert_equal "4bf92f3577b34da6a3ce929d0e0e4736", span.trace_id.unpack1("H*"),
                 "the inbound traceparent did not become the span's parent. Without this the " \
                 "collector shows a trace per request and no trace per caller, which is the " \
                 "whole reason the header is read."
    assert_no_canary
  end


  test "a refused request's problem document reaches no span" do
    post "/v1/customers", params: { customer: { email: CANARY } }

    assert_includes [ 201, 422 ], response.status
    rendered = TestSupport::TestSpans.rendered!
    refute_includes rendered, response.body
  end

  test "a 404's span carries a status and no message" do
    get "/v1/does-not-exist"

    assert_response :not_found
    span = TestSupport::TestSpans.request_spans.first
    assert_equal 404, span.attributes["http.response.status_code"]
    assert_no_canary
  end

  private

  # The presence assertion, in every test above.
  #
  # `rendered!/0` raises when the export is empty, so this is simultaneously "the
  # canary is absent" and "something was exported". A test that only ever asserted
  # absence would be satisfied by a billing that records nothing, which is the
  # failure three separate bugs produced while this was being written.
  def assert_no_canary
    exported = TestSupport::TestSpans.rendered!

    if exported.include?(CANARY)
      raise <<~MESSAGE

        THE REDACTION BOUNDARY LEAKED.

        field a caller controls, so whatever route it took is a route by which a customer's
        email, a processor id, a signing secret, a bearer token or an entire webhook body
        reaches a searchable, retained, widely-readable store — and this service holds prices
        in minor units and a customer's whole subscription history, so those are the values it
        most cannot afford to publish.

        The whole export:

      MESSAGE
    end

    exported
  end
end
