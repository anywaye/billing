require "test_helper"

class ObservabilityRequestSpanTest < ActionDispatch::IntegrationTest
  CANARY = "CANARY-4e1b-DO-NOT-EXPORT"

  setup do
    travel_to(frozen_now)
    TestSupport::TestSpanExporter.clear!
  end

  teardown do
    TestSupport::TestSpanExporter.clear!
  end


  test "every request exports exactly one span, named billing.http.request" do
    get "/healthz"

    assert_response :success
    spans = TestSupport::TestSpans.request_spans
    assert_equal 1, spans.size
    assert_equal "billing.http.request", spans.first.name
  end

  test "the span carries the method and the status" do
    get "/healthz"

    attributes = TestSupport::TestSpans.request_spans.first.attributes
    assert_equal "GET", attributes["http.request.method"]
    assert_equal 200, attributes["http.response.status_code"]
  end

  test "the span carries the ROUTE TEMPLATE, and the probe's template is its path" do
    get "/healthz"

    assert_equal "/healthz", route_attribute
  end

  test "a parameterised route exports its TEMPLATE, never the concrete path" do
    customer = a_customer

    get "/v1/customers/#{customer.id}"

    assert_equal "/v1/customers/:id", route_attribute,
                 "the span carries the concrete id in its route.\n\n" \
                 "A route template has one value per endpoint; a concrete path has one per " \
                 "request, and kit's collector derives metrics with a `spanmetrics` connector " \
                 "that mints a metric series for every distinct value. Nothing downstream can " \
                 "tell them apart: both are on core's allowlist and both pass the redaction " \
                 "processor. This is a service-side choice, which is why it is tested here and " \
                 "not left to the collector."
    refute_includes TestSupport::TestSpans.rendered!, customer.id,
                    "the caller's own id reached a span attribute"
  end

  test "the same path template reads differently per VERB, because the lookup is keyed by verb" do
    plan = a_plan

    patch "/v1/plans/#{plan.id}", params: { plan: { name: "Pro Plus" } }
    assert_equal "/v1/plans/:id", route_attribute

    TestSupport::TestSpanExporter.clear!

    get "/v1/plans/#{plan.slug}"
    assert_equal "/v1/plans/:slug", route_attribute
  end

  test "a sub-resource verb records its OWN template, not its parent's" do
    subscription = a_subscription(a_customer)

    post "/v1/subscriptions/#{subscription.id}/cancel"

    assert_equal "/v1/subscriptions/:id/cancel", route_attribute
  end

  test "every route this service serves is in the derived route table" do
    served = Rails.application.routes.routes.filter_map do |route|
      controller = route.defaults[:controller]
      action = route.defaults[:action]
      next if controller.nil? || action.nil?
      next unless controller.start_with?("v1/", "webhooks/", "health", "errors")

      [ route.verb.to_s, controller, action ]
    end

    missing = served.reject { |key| Kit::Telemetry.route_templates.key?(key) }

    assert_empty missing,
                 "the router serves routes the telemetry route table does not know: #{missing.inspect}.\n\n" \
                 "A request to one of those exports a span with no `http.route`, which is " \
                 "invisible in a trace view and makes the route's error rate unattributable."
  end


  test "a 404 carries NO route at all" do
    get "/v1/no-such-thing/#{SecureRandom.hex(4)}"

    assert_response :not_found
    span = TestSupport::TestSpans.request_spans.first
    refute span.attributes.key?("http.route"),
           "a 404 produced a span with a route. The path of an unmatched request is " \
           "caller-controlled text, so recording it is the cardinality bomb and the content " \
           "leak in one move; the 404 status is the answer."
  end

  test "a 404 is not an ERROR span" do
    get "/v1/no-such-thing"

    assert_response :not_found
    span = TestSupport::TestSpans.request_spans.first
    assert_nil span.attributes["error.type"],
               "a 404 was recorded as an error. A 404 is this service REFUSING a request, " \
               "which is this service working; an error rate that counts it is a function of " \
               "how much guessing the internet absorbs, and an alert on it pages somebody to " \
               "switch off the protection doing its job."
    assert_predicate span.status, :ok?,
                    "a 404 produced a span whose status is ERROR, which is the other half of the " \
                    "same claim and is what an error rate and a dashboard both read"
  end

  test "a 422 is not an ERROR span either" do
    post "/v1/customers", params: { customer: { email: "not-an-email" } }

    assert_response :unprocessable_entity
    assert_predicate TestSupport::TestSpans.request_spans.first.status, :ok?
    assert_nil TestSupport::TestSpans.request_spans.first.attributes["error.type"]
  end

  test "a 500 IS an error span, and carries the closed error.type" do
    raising_request!

    span = TestSupport::TestSpans.request_spans.first
    assert_equal 500, span.attributes["http.response.status_code"]
    assert_equal "unhandled_exception", span.attributes["error.type"]
    assert_includes Kit::Telemetry::ERROR_TYPES, span.attributes["error.type"]
    refute_predicate span.status, :ok?,
                    "a 500 produced a span whose status is not ERROR, which is what an error " \
                    "rate and a dashboard both read"
  end

  test "a raised exception's MESSAGE and STACKTRACE are not on the span" do
    raising_request!(message: "no such customer: #{CANARY}@example.com")

    rendered = TestSupport::TestSpans.rendered!
    span = TestSupport::TestSpans.request_spans.first

    assert_empty Array(span.events),
                 "the exception was recorded as a span EVENT, and an event is exported. Its " \
                 "message is attacker- or caller-shaped text by the time it is three frames up, " \
                 "and its stacktrace names files and methods. `tracer.in_span` does this by " \
                 "default, which is why this middleware calls `start_span` and never " \
                 "`record_exception`.\n\n#{rendered}"
    refute_includes rendered, CANARY
    assert_equal RequestTelemetry::FAILURE_DESCRIPTION, span.status.description,
                 "the status description is an exception class name written by the SDK, not one " \
                 "of this repository's constants"
  end


  test "the resource names the service and omits every value nobody configured" do
    resource = Kit::Telemetry.resource(->(_name) { "" })

    attributes = resource.attribute_enumerator.to_h
    assert_equal "billing", attributes["service.name"]
    refute attributes.key?("service.version"),
           "`service.version` was set to an empty string rather than omitted. A collector that " \
           "groups by it grows a second service row distinguished by nothing, and an operator " \
           "looking at a service list sees the same service twice."
    refute attributes.key?("tenant_id")
    refute attributes.key?("deployment.environment")
  end

  test "the resource carries the version, the environment and the tenant when they ARE set" do
    resource = Kit::Telemetry.resource(lambda do |name|
      {
        "OTEL_SERVICE_VERSION" => "1.2.3",
        "DEPLOYMENT_ENVIRONMENT" => "production",
        "BILLING_TENANT_ID" => "acme"
      }.fetch(name, "")
    end)

    attributes = resource.attribute_enumerator.to_h
    assert_equal "1.2.3", attributes["service.version"]
    assert_equal "production", attributes["deployment.environment"]
    assert_equal "acme", attributes["tenant_id"]
  end

  test "tenant_id is a RESOURCE attribute and never a span attribute" do
    assert_includes Kit::Telemetry.resource(->(_n) { "" }).attribute_enumerator.to_h.keys, "service.name"
    refute_includes Kit::Telemetry::ALLOWED_SPAN_ATTRIBUTES, "tenant_id"

    get "/healthz"
    refute TestSupport::TestSpans.request_spans.first.attributes.key?("tenant_id")
  end


  test "a ROOT span is sampled, because the SDK default is parent_based with an always_on root" do
    result = OpenTelemetry.tracer_provider.sampler.should_sample?(
      trace_id: "4bf92f3577b34da6a3ce929d0e0e4736",
      parent_context: nil,
      links: nil,
      name: Kit::Telemetry::REQUEST_SPAN_NAME,
      kind: :server,
      attributes: {}
    )

    assert result.recording?, "the installed sampler would not record a root span"
    assert result.sampled?, "the installed sampler would not SAMPLE a root span. A request with " \
                           "no inbound traceparent is not sampled, and a service that looks " \
                           "configured exports nothing."
  end

  private

  def route_attribute
    TestSupport::TestSpans.request_spans.first.attributes["http.route"]
  end

  ACCOUNT_ID = "11111111-1111-4111-8111-111111111111"

  def a_customer
    Customer.create!(owner_type: "Account", owner_id: ACCOUNT_ID, processor: "stripe",
                     processor_customer_id: "cus_FAKE#{SecureRandom.hex(8)}")
  end

  def a_plan
    Plan.create!(name: "Pro", slug: "pro-#{SecureRandom.hex(6)}", price: Billing::Money.new(1_900, "USD"),
                 interval: "month", processor_price_id: "price_FAKE#{SecureRandom.hex(8)}")
  end

  def a_subscription(customer)
    Subscription.create!(customer: customer, account_id: ACCOUNT_ID, plan: a_plan, status: "active",
                         processor_subscription_id: "sub_FAKE#{SecureRandom.hex(8)}")
  end

  def raising_request!(message: "the handler raised")
    app = RequestTelemetry.new(->(_env) { raise message })

    assert_raises(RuntimeError) do
      app.call(Rack::MockRequest.env_for("http://example.org/boom"))
    end
  end
end
