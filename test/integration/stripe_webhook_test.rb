require "test_helper"

class StripeWebhookTest < ActionDispatch::IntegrationTest
  setup do
    travel_to(frozen_now)
  end

  test "a signed event is accepted" do
    post_stripe_webhook(stripe_fixture("invoice.paid"))

    assert_response :ok
    assert_equal 1, ProcessorWebhook.count
  end

  test "a signed event emits exactly one internal event" do
    post_stripe_webhook(stripe_fixture("invoice.paid"))

    assert_equal 1, OutboxEvent.count
  end

  test "the endpoint is not wrapped in an HTML error page on failure" do
    post_stripe_webhook(stripe_fixture("invoice.paid"), secret: "whsec_the_wrong_secret")

    assert_response :bad_request
    assert_equal "application/problem+json", response.media_type
  end

  test "a bad signature is rejected" do
    post_stripe_webhook(stripe_fixture("invoice.paid"), secret: "whsec_the_wrong_secret")

    assert_response :bad_request
  end

  test "a bad signature stores nothing" do
    post_stripe_webhook(stripe_fixture("invoice.paid"), secret: "whsec_the_wrong_secret")

    assert_equal 0, ProcessorWebhook.count
    assert_equal 0, OutboxEvent.count
  end

  test "a tampered body is rejected even when the signature was valid for the original" do
    original = stripe_fixture("invoice.paid")
    tampered = original.sub("\"amount_paid\": 8700", "\"amount_paid\": 87")

    post StripeWebhookHelpers::STRIPE_WEBHOOK_PATH, params: tampered,
      headers: {
        "CONTENT_TYPE" => "application/json",
        "Stripe-Signature" => stripe_signature(original)
      }

    assert_response :bad_request
    assert_equal 0, ProcessorWebhook.count
  end

  test "a missing signature header is rejected" do
    post StripeWebhookHelpers::STRIPE_WEBHOOK_PATH, params: stripe_fixture("invoice.paid"), headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :bad_request
    assert_equal 0, ProcessorWebhook.count
  end

  test "a signature older than the tolerance window is rejected" do
    payload = stripe_fixture("invoice.paid")

    post_stripe_webhook(payload, timestamp: 10.minutes.ago.to_i)

    assert_response :bad_request
    assert_equal 0, ProcessorWebhook.count
  end

  test "a signature just inside the tolerance window is accepted" do
    payload = stripe_fixture("invoice.paid")

    post_stripe_webhook(payload, timestamp: 4.minutes.ago.to_i)

    assert_response :ok
    assert_equal 1, ProcessorWebhook.count
  end

  test "a signature that verifies under either configured secret is accepted" do
    payload = stripe_fixture("invoice.paid")

    with_stripe_secrets("whsec_old_secret", "whsec_new_secret") do
      post_stripe_webhook(payload, secret: "whsec_old_secret")
    end

    assert_response :ok
    assert_equal 1, ProcessorWebhook.count
  end

  test "a signature that verifies under the second of two configured secrets is accepted" do
    payload = stripe_fixture("invoice.paid")

    with_stripe_secrets("whsec_old_secret", "whsec_new_secret") do
      post_stripe_webhook(payload, secret: "whsec_new_secret")
    end

    assert_response :ok
  end

  test "a signature that verifies under neither configured secret is rejected" do
    payload = stripe_fixture("invoice.paid")

    with_stripe_secrets("whsec_old_secret", "whsec_new_secret") do
      post_stripe_webhook(payload, secret: "whsec_some_other_secret")
    end

    assert_response :bad_request
    assert_equal 0, ProcessorWebhook.count
  end

  test "a single configured secret is accepted" do
    payload = stripe_fixture("invoice.paid")

    post_stripe_webhook(payload, secret: StripeWebhookHelpers::WEBHOOK_SECRET)

    assert_response :ok
  end

  test "an unconfigured signing secret is a server error, not a bad request" do
    with_env("STRIPE_WEBHOOK_SECRET" => nil) do
      post_stripe_webhook(stripe_fixture("invoice.paid"))
    end

    assert_response :service_unavailable
    assert_equal 0, ProcessorWebhook.count
  end

  test "an unconfigured signing secret is the same problem body as any other 503" do
    with_env("STRIPE_WEBHOOK_SECRET" => nil) do
      post_stripe_webhook(stripe_fixture("invoice.paid"))
    end

    assert_problem "unavailable"
  end

  test "an unconfigured signing secret never claims the signature was invalid" do
    with_env("STRIPE_WEBHOOK_SECRET" => nil) do
      post_stripe_webhook(stripe_fixture("invoice.paid"))
    end

    refute_equal "bad_request", response.parsed_body["code"]
  end

  test "an unconfigured signing secret is logged with its cause, and the body says nothing about it" do
    logged = with_env("STRIPE_WEBHOOK_SECRET" => nil) do
      capture_log { post_stripe_webhook(stripe_fixture("invoice.paid")) }
    end

    assert_includes logged, "SignaturesUnconfigured"
    assert_no_match(/whsec/, response.body)
  end

  test "a malformed body with a valid signature over it is rejected" do
    post_stripe_webhook("this is not json")

    assert_response :bad_request
    assert_equal 0, ProcessorWebhook.count
  end

  test "a replayed event is accepted and processed once" do
    payload = stripe_fixture("invoice.paid")

    post_stripe_webhook(payload)
    post_stripe_webhook(payload)

    assert_response :ok
    assert_equal 1, ProcessorWebhook.count
    assert_equal 1, OutboxEvent.count
  end

  test "a replayed subscription event emits one event, not two" do
    payload = stripe_fixture("customer.subscription.created")

    with_resolvable_subscription do
      post_stripe_webhook(payload)
      post_stripe_webhook(payload)
    end

    assert_equal 1, OutboxEvent.where(event_type: "billing.subscription.started").count
  end

  test "a replay carries the same response as the first delivery" do
    payload = stripe_fixture("invoice.paid")

    post_stripe_webhook(payload)
    first_status = response.status
    post_stripe_webhook(payload)

    assert_equal first_status, response.status
  end

  test "a deletion arriving before its creation is accepted" do
    with_resolvable_subscription do
      post_stripe_webhook(stripe_fixture("customer.subscription.deleted"))
      post_stripe_webhook(stripe_fixture("customer.subscription.created"))
    end

    assert_response :ok
    assert_equal 2, ProcessorWebhook.where("type LIKE 'customer.subscription.%'").count
  end

  test "a deletion arriving before its creation leaves the subscription canceled" do
    with_resolvable_subscription do
      post_stripe_webhook(stripe_fixture("customer.subscription.deleted"))
      post_stripe_webhook(stripe_fixture("customer.subscription.created"))
    end

    assert_equal "canceled", Subscription.sole.status
    refute_predicate Subscription.sole, :grants_entitlements?
  end

  test "a deletion arriving before its creation is the only event, because nothing started" do
    with_resolvable_subscription do
      post_stripe_webhook(stripe_fixture("customer.subscription.deleted"))
      post_stripe_webhook(stripe_fixture("customer.subscription.created"))
    end

    assert_equal [ "billing.subscription.canceled" ], subscription_event_types
  end

  test "an update arriving before its creation is accepted" do
    with_resolvable_subscription do
      post_stripe_webhook(stripe_fixture("customer.subscription.updated"))
      post_stripe_webhook(stripe_fixture("customer.subscription.created"))
    end

    assert_response :ok
    assert_equal 2, ProcessorWebhook.where("type LIKE 'customer.subscription.%'").count
  end

  test "an update arriving before its creation records why it was refused" do
    with_resolvable_subscription do
      post_stripe_webhook(stripe_fixture("customer.subscription.updated"))
      post_stripe_webhook(stripe_fixture("customer.subscription.created"))
    end

    assert_equal "ignored:no_subscription_to_update", ProcessorWebhook.find_by(type: "customer.subscription.updated").error
  end

  test "a delivery naming another account is refused, and the endpoint still answers 200" do
    create_stripe_customer(account_id: TwoAccounts::ACCOUNT_A, processor_customer_id: TwoAccounts::CUSTOMER_A)
    other = create_stripe_customer(account_id: TwoAccounts::ACCOUNT_B, processor_customer_id: TwoAccounts::CUSTOMER_B)
    create_stripe_plan

    post_stripe_webhook(subscription_delivery_named("customer.subscription.created", TwoAccounts::CUSTOMER_A))
    assert_response :ok
    row = Subscription.sole
    assert_equal TwoAccounts::ACCOUNT_A, row.account_id

    post_stripe_webhook(
      subscription_delivery_named("customer.subscription.updated", TwoAccounts::CUSTOMER_B, customer_record: other)
    )

    assert_response :ok,
      "a refused delivery must not be answered with a 4xx or a 5xx. The processor retries a " \
      "non-2xx, the retry reaches the identical decision, and the delivery row already " \
      "carries the reason."
    assert_equal "ignored:account_mismatch", ProcessorWebhook.find_by(type: "customer.subscription.updated").error
    assert_equal TwoAccounts::ACCOUNT_A, row.reload.account_id,
      "the subscription moved between accounts. `Lifecycle#apply` compares the resolved " \
      "account with the one on the row and refuses before `assign_attributes`."
    refute_equal other.id, row.customer_id,
      "the subscription now points at the other account's customer. The account is derived " \
      "from the customer on every apply, so the two move together or not at all."
  end

  test "each delivery keeps the time the processor reported" do
    with_resolvable_subscription do
      post_stripe_webhook(stripe_fixture("customer.subscription.created"))
      travel_to 1.hour.from_now
      post_stripe_webhook(stripe_fixture("customer.subscription.deleted"))
    end

    started, canceled = OutboxEvent.where(event_type: SUBSCRIPTION_EVENTS).order(:created_at, :id).to_a

    assert_equal Time.utc(2026, 9, 30, 4, 0, 0), started.time
    assert_equal Time.utc(2026, 11, 14, 4, 0, 0), canceled.time
  end

  test "an unknown event type is accepted and stored" do
    post_stripe_webhook(stripe_fixture("charge.succeeded"))

    assert_response :ok
    assert_equal 1, ProcessorWebhook.count
    assert_equal "charge.succeeded", ProcessorWebhook.sole.type
  end

  test "an unknown event type emits nothing" do
    post_stripe_webhook(stripe_fixture("charge.succeeded"))

    assert_equal 0, OutboxEvent.count
  end

  test "a deliberately ignored event type is accepted" do
    post_stripe_webhook(stripe_fixture("ping"))

    assert_response :ok
  end

  test "a processor's own connectivity check is not treated as money" do
    post_stripe_webhook(stripe_fixture("ping"))

    assert_equal 0, OutboxEvent.count
  end

  test "a subscription-mode checkout session is accepted and emits nothing" do
    post_stripe_webhook(stripe_fixture("checkout.session.completed"))

    assert_response :ok
    assert_equal 0, OutboxEvent.count
  end

  test "a subscription-mode checkout session records why it was ignored" do
    post_stripe_webhook(stripe_fixture("checkout.session.completed"))

    assert_equal "ignored:subscription_mode_is_restated_by_the_subscription_lifecycle", ProcessorWebhook.sole.error
  end

  test "a subscription signup states one fact once, not once per delivery channel" do
    with_resolvable_subscription do
      post_stripe_webhook(stripe_fixture("checkout.session.completed"))
      post_stripe_webhook(stripe_fixture("customer.subscription.created"))
    end

    assert_equal [ "billing.subscription.started" ], subscription_event_types
  end

  test "a signed body that is not JSON is rejected" do
    post_stripe_webhook("this is not json, but it is signed")

    assert_response :bad_request
    assert_equal 0, ProcessorWebhook.count
  end

  SIGNED_NON_OBJECTS = {
    "an array" => "[1,2,3]",
    "an empty array" => "[]",
    "a number" => "5",
    "a string" => '"a string"',
    "a boolean" => "true",
    "null" => "null"
  }.freeze

  SIGNED_NON_OBJECTS.each do |shape, body|
    test "a signed body that is #{shape} is rejected rather than raising" do
      post_stripe_webhook(body)

      assert_response :bad_request
      assert_equal 0, ProcessorWebhook.count
      assert_equal 0, OutboxEvent.count
    end
  end

  test "every signed body that is not an object answers with this service's problem body" do
    SIGNED_NON_OBJECTS.each_value do |body|
      post_stripe_webhook(body)

      assert_problem "bad_request"
    end
  end

  test "a signed body that is not an object does not claim the signature was invalid" do
    post_stripe_webhook("[1,2,3]")

    assert_equal "The verified body is not a Stripe event.", json_body["detail"]
  end

  test "a signed body that is not an object is answered with the same status as one that is not JSON" do
    post_stripe_webhook("[1,2,3]")
    non_object_status = response.status
    post_stripe_webhook("this is not json, but it is signed")

    assert_equal non_object_status, response.status
  end

  test "a signed body with no event type is rejected" do
    post_stripe_webhook({ "id" => "evt_untyped", "data" => { "object" => {} } }.to_json)

    assert_response :bad_request
    assert_equal 0, ProcessorWebhook.count
  end

  test "an event whose mapping fails is answered 200, so the processor stops retrying" do
    post_stripe_webhook({ "id" => "evt_bare", "type" => "invoice.paid" }.to_json)

    assert_response :ok
    assert_equal 1, ProcessorWebhook.count
    assert_predicate ProcessorWebhook.sole.error, :present?
    assert_equal 0, OutboxEvent.count
  end

  test "a body signed but missing the fields an event needs is recorded as failed" do
    post_stripe_webhook({ "id" => "evt_bare", "type" => "invoice.paid" }.to_json)

    assert ProcessorWebhook.sole.error.start_with?("failed:"), "expected a parked row, got: #{ProcessorWebhook.sole.error.inspect}"
  end

  test "a failed event is logged with the processor event id, so the row is findable" do
    logged = capture_log { post_stripe_webhook({ "id" => "evt_logged", "type" => "invoice.paid" }.to_json) }

    assert_includes logged, "evt_logged"
  end

  test "the endpoint answers the same status for every signature failure" do
    post_stripe_webhook(stripe_fixture("invoice.paid"), secret: "whsec_wrong")
    bad_signature_status = response.status
    post StripeWebhookHelpers::STRIPE_WEBHOOK_PATH, params: stripe_fixture("invoice.paid"), headers: { "CONTENT_TYPE" => "application/json" }
    missing_signature_status = response.status

    assert_equal bad_signature_status, missing_signature_status
  end

  test "a rejected signature answers with this service's problem body" do
    post_stripe_webhook(stripe_fixture("invoice.paid"), secret: "whsec_wrong")

    assert_problem "bad_request"
  end

  test "a rejected signature's body distinguishes a bad signature from a body that is not an event" do
    post_stripe_webhook(stripe_fixture("invoice.paid"), secret: "whsec_wrong")
    bad_signature_detail = json_body["detail"]

    post_stripe_webhook("this is not json, but it is signed")
    malformed_detail = json_body["detail"]

    assert_not_equal bad_signature_detail, malformed_detail
  end

  test "a rejection is logged with its cause, so an operator can tell the two apart" do
    logged = capture_log { post_stripe_webhook(stripe_fixture("invoice.paid"), secret: "whsec_wrong") }

    assert_includes logged, "UnverifiedSignature"
  end

  test "an error body carries a trace id, so support can start from it" do
    post_stripe_webhook(stripe_fixture("invoice.paid"), secret: "whsec_wrong")

    assert_predicate response.parsed_body["trace_id"].to_s, :present?
  end

  HANDLED_TYPES = {
    "invoice.paid" => "billing.payment.succeeded",
    "invoice.payment_failed" => "billing.payment.failed",
    "checkout.session.completed.payment" => "billing.payment.succeeded"
  }.freeze

  HANDLED_TYPES.each do |fixture, event_type|
    test "#{fixture} emits #{event_type}" do
      post_stripe_webhook(stripe_fixture(fixture))

      assert_response :ok
      assert_equal event_type, OutboxEvent.sole.event_type
    end
  end

  test "customer.subscription.created emits billing.subscription.started" do
    with_resolvable_subscription do
      post_stripe_webhook(stripe_fixture("customer.subscription.created"))
    end

    assert_response :ok
    assert_equal [ "billing.subscription.started" ], subscription_event_types
  end

  test "a subscription is started, updated and then canceled, in that order" do
    with_resolvable_subscription do
      post_stripe_webhook(stripe_fixture("customer.subscription.created"))
      travel_to 1.hour.from_now
      post_stripe_webhook(stripe_fixture("customer.subscription.updated"))
      travel_to 2.hours.from_now
      post_stripe_webhook(stripe_fixture("customer.subscription.deleted"))
    end

    assert_equal(
      [ "billing.subscription.started", "billing.subscription.updated", "billing.subscription.canceled" ],
      subscription_event_types
    )
  end

  test "every subscription event is correlated on this service's own subscription" do
    with_resolvable_subscription do
      post_stripe_webhook(stripe_fixture("customer.subscription.created"))
      travel_to 1.hour.from_now
      post_stripe_webhook(stripe_fixture("customer.subscription.updated"))
    end

    assert_equal [ Subscription.sole.id ], OutboxEvent.where(event_type: SUBSCRIPTION_EVENTS).pluck(:subject).uniq
  end

  SUBSCRIPTION_EVENTS = %w[
    billing.subscription.started
    billing.subscription.updated
    billing.subscription.canceled
  ].freeze

  def subscription_event_types
    OutboxEvent.where(event_type: SUBSCRIPTION_EVENTS).order(:created_at, :id).pluck(:event_type)
  end

  test "every type this endpoint can emit is one the outbox has declared" do
    assert_empty HANDLED_TYPES.values.uniq - OutboxEvent::TYPES
  end

  test "every handled type lands in the manifest's events list" do
    manifest_events = YAML.load_file(Rails.root.join("anywaye.yml")).dig("exposes", "events")

    assert_empty HANDLED_TYPES.values.uniq - manifest_events
  end

  test "the endpoint is served at the path the OpenAPI document declares" do
    document = YAML.load_file(Rails.root.join("openapi/v1.yaml"))

    assert_includes document.fetch("paths").keys, StripeWebhookHelpers::STRIPE_WEBHOOK_PATH
  end

  test "the manifest points at the OpenAPI document that declares the endpoint" do
    manifest = YAML.load_file(Rails.root.join("anywaye.yml"))

    assert_equal "openapi/v1.yaml", manifest.dig("exposes", "api")
  end

  test "the endpoint is served" do
    post_stripe_webhook(stripe_fixture("invoice.paid"))

    assert_response :ok
  end

  test "the health probes are unaffected by the webhook surface" do
    get "/healthz"

    assert_response :ok
  end

  private
    def with_stripe_secrets(*secrets)
      with_env("STRIPE_WEBHOOK_SECRETS" => secrets.join(",")) { yield }
    end

    def with_resolvable_subscription
      create_stripe_customer
      create_stripe_plan
      yield
    end

    def subscription_delivery_named(fixture, processor_customer_id, customer_record: nil)
      body = JSON.parse(stripe_fixture(fixture))
      object = body.dig("data", "object")
      record = customer_record || Customer.find_by!(processor_customer_id: processor_customer_id)

      object["customer"] = processor_customer_id
      object["metadata"] = { "anywaye_customer_id" => record.id }

      JSON.generate(body)
    end
end
