require "test_helper"

# The request span, driven through the REAL router over REAL requests.
#
# The allowlist is asserted on directly in `AllowlistTest`; this file is the other
# half, and it is the half that cannot be satisfied by a correct list. A service
# whose `ALLOWED_SPAN_ATTRIBUTES` is perfect and whose middleware records the
# concrete request path, the query string and the headers passes every allowlist
# assertion there is and leaks on every request. So these are integration tests:
# they drive requests through the whole stack and read what actually came out.
#
# The presence assertion is in every one of them, through `TestSpans.rendered!`,
# which RAISES on an empty export. Every absence assertion here is therefore also a
# presence one — see `TestSpanExporter` for the three exporter-contract bugs that
# made that necessary.
class ObservabilityRequestSpanTest < ActionDispatch::IntegrationTest
  # Short, in no allowlist, and in no expected output. Its job is to be a string
  # nothing in this repository would produce by accident, so a match is a leak and
  # not a coincidence.
  CANARY = "CANARY-4e1b-DO-NOT-EXPORT"

  setup do
    travel_to(frozen_now)
    TestSupport::TestSpanExporter.clear!
  end

  teardown do
    TestSupport::TestSpanExporter.clear!
  end

  # --- what is always there -------------------------------------------------

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

  # THE CARDINALITY GUARANTY, and the only test on this page that could not be
  # written any other way.
  #
  # A template has one value per endpoint; a concrete path has one per request.
  # `/healthz` cannot tell the two apart — for that route the template and the path
  # are the same string — so the assertion that matters is on a route with an
  # `:id` in it, where the two differ on every request but the first.
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
    # `GET /v1/plans/:slug` and `PATCH /v1/plans/:id` are two templates over
    # similar text. A lookup keyed on the path alone would pick one of them for
    # both, and a span would attribute a failure to an endpoint that cannot produce
    # it — which is the failure mode a metric per route is supposed to prevent.
    plan = a_plan

    patch "/v1/plans/#{plan.id}", params: { plan: { name: "Pro Plus" } }
    assert_equal "/v1/plans/:id", route_attribute

    # Cleared BETWEEN the two requests, and this is a real trap rather than
    # tidiness. The exporter accumulates for the whole test — that is what makes the
    # absence assertions meaningful — so a helper that reads the FIRST request span
    # after a second request is still asserting about the first one. The two
    # templates here are the ones a single-lookup implementation gets wrong, so a
    # test that accidentally read the PATCH's span would pass.
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

  # --- what is deliberately absent -------------------------------------------

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
    # `ok?` rather than `status == OK`: see the 422 test below. UNSET is `ok?`, and
    # a 404 leaves the span UNSET.
    assert_predicate span.status, :ok?,
                    "a 404 produced a span whose status is ERROR, which is the other half of the " \
                    "same claim and is what an error rate and a dashboard both read"
  end

  test "a 422 is not an ERROR span either" do
    post "/v1/customers", params: { customer: { email: "not-an-email" } }

    assert_response :unprocessable_entity
    # `ok?` and NOT `status == OK`, and the difference is the whole assertion.
    # `OpenTelemetry::Trace::Status` has THREE codes — `OK = 0`,
    # `UNSET = 1`, `ERROR = 2` — and `ok?` is defined as `code != ERROR`. So a
    # span nobody marked is UNSET, and UNSET is `ok?`. An assertion written as
    # `assert_equal OpenTelemetry::Trace::Status::OK, span.status.code` would fail
    # here while the span behaved exactly as intended, and the fix somebody would
    # reach for is to mark every successful span OK — which changes what a
    # downstream collector counts as "the service set a status" for no gain.
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
    # The sharpest case in this file, and the reason the middleware uses
    # `start_span` rather than `tracer.in_span`.
    #
    # `in_span` calls `span.record_exception(e)` by default, which attaches the
    # class name, the MESSAGE and the stacktrace as a span EVENT — and an event is
    # exported. An exception message in this service is built three frames up from
    # what a caller sent; `test/integration/secrets_do_not_leak_test.rb` exists
    # because that is where leaks live, and the span is a second place the same
    # string would land.
    raising_request!(message: "no such customer: #{CANARY}@example.com")

    # `rendered!` FIRST, so an empty export raises here rather than making the
    # assertions below vacuous. A boundary that recorded nothing would satisfy
    # "no exception event" perfectly.
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

  # --- the resource ----------------------------------------------------------

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

  # --- the sampler -----------------------------------------------------------

  test "a ROOT span is sampled, because the SDK default is parent_based with an always_on root" do
    # Asked of the INSTALLED provider rather than asserted about the constant in
    # `Kit::TracerInstaller`, because `Kit::TracerInstaller` deliberately does not
    # pin a sampler — it takes the SDK's default, which is
    # `Samplers.parent_based(root: Samplers::ALWAYS_ON)`, and still honours
    # `OTEL_TRACES_SAMPLER`. A default that changed would leave every request here
    # exporting nothing, so the default is a TEST rather than a comment.
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

  # Rows built here rather than from `test/fixtures/`, and this repository has no
  # Active Record fixtures at all — `fixtures :all` loads only `test/fixtures/stripe`,
  # which is committed webhook BYTES. A row this test needs is therefore created,
  # and its id is a real uuid generated per run, which is what makes the
  # template-not-path assertion meaningful: there is nothing in the template that
  # could accidentally match the id.
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

  # Drive `RequestTelemetry` with a raising inner app, and assert that it re-raised.
  #
  # It replaces the INNERMOST app and nothing else, so the layer under test is the
  # one that ships. Two alternatives were rejected and both for the same reason:
  #
  #   * swapping out the whole router, which produced a 500 on a span with no route
  #     on it — a test asserting about a service that is not the one that ships;
  #   * adding a real route that raises, whose 500 arrives through Rails' own
  #     exception handling. That handling lives ABOVE this middleware, so the span
  #     the middleware produced would be the one under test while the response
  #     came from somewhere the middleware does not see — and the 500's
  #     `error.type` would then be this repository's `Error#unhandled_exception`
  #     rather than the one the middleware itself sets.
  #
  # `Rack::MockRequest.env_for` rather than `get "/boom"`, because there is no such
  # route and inventing one would be the second alternative.
  def raising_request!(message: "the handler raised")
    app = RequestTelemetry.new(->(_env) { raise message })

    assert_raises(RuntimeError) do
      app.call(Rack::MockRequest.env_for("http://example.org/boom"))
    end
  end
end
