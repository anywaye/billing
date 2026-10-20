require "test_helper"

# THE LOCK. `/v1` cannot be reached without a valid identity token, and everything
# that is not `/v1` still can.
#
# # What this file is, and why the assertions are shaped this way
#
# The brief's own failure mode is "a billing API with auth that degrades open", so
# every refusal here is asserted in **both** directions that matter:
#
#   1. **Every `/v1` operation is refused without a token** — and the list comes
#      from `config/routes.rb`, not from a table written here. A test that named
#      the fourteen paths in this file would pass while a route added tomorrow went
#      out unauthenticated, which is the one thing this file exists to prevent.
#   2. **Every operation that is NOT a client operation still works with no token**
#      — the probes (an orchestrator has no credential) and the Stripe webhook (its
#      sender is a processor, and core's conventions say inbound webhooks are
#      signed, never JWT-authenticated). Also derived from the router.
#
# The direction that finds things is the first one. That is deliberate and it is
# why it reads the route table.
#
# # Why the two locks are 401 and 503, and not one of them
#
#   * **No token, or a token that is wrong** — the caller's problem, and a 401 is
#     the answer that tells them so. One fixed body for all of it: which of
#     signature / expiry / issuer / audience was wrong is not something a caller
#     learns by trying.
#   * **No identity configured, or identity unreachable** — *our* problem, and a
#     401 would tell a caller holding a perfectly good token to go and rotate it.
#     This is the same reasoning the webhook uses for a missing signing secret.
#
# So the two are asserted separately, and **the 503 assertions are the ones that
# prove the lock fails closed**: a deployment that has not configured identity
# refuses every request rather than serving every request.
class PrincipalLockTest < ActionDispatch::IntegrationTest
  # Every `/v1` operation the router serves, as `[method, path]`, read from the
  # routes rather than written here. `/v1/webhooks/stripe` is excluded **by the
  # router's own controller**, not by a prefix filter: `Webhooks::BaseController`
  # is not a `V1::` controller and does not inherit the concern, which is the
  # structural fact this file is checking.
  CLIENT_OPERATIONS = lambda {
    Rails.application.routes.routes.flat_map { |route|
      path = route.path.spec.to_s.sub("(.:format)", "")
      next [] unless path.start_with?("/v1")
      next [] if path.start_with?("/v1/webhooks")

      route.verb.split("|").map { |verb| [ verb, path ] }
    }.uniq
  }

  # Probes and Rails' own health route. An uptime monitor and an orchestrator have
  # no credential and must not be refused: a probe that answers 401 is a probe that
  # reports the service as down and restarts it, which is strictly worse than
  # serving traffic with no traces.
  UNAUTHENTICATED_SURFACE = [
    [ "GET", "/healthz" ],
    [ "GET", "/readyz" ],
    [ "GET", "/up" ],
    [ "POST", "/v1/webhooks/stripe" ]
  ].freeze

  setup do
    travel_to(frozen_now)
  end

  # --- direction one: every /v1 operation is locked ---------------------------

  test "every /v1 operation is refused with no token, and the list is the router's own" do
    assert_equal 24, CLIENT_OPERATIONS.call.size,
      "the number of client operations changed. Re-read the exclusion above rather than " \
      "adding to it — a route that arrived unauthenticated is what this count is for."

    CLIENT_OPERATIONS.call.each do |method, path|
      without_token!

      send_request(method, path)

      assert_includes [ 401, 503 ], response.status,
        "#{method} #{path} answered #{response.status} with no token. Every client operation on " \
        "/v1 must refuse an unauthenticated caller."
    end
  end

  test "the lock is 401 with no token, not 503" do
    # Pinned separately from the loop above because the loop tolerates either status
    # and this is the claim that with a *working* identity a missing token is the
    # caller's problem. A 503 here would mean the request never reached the verifier.
    without_token!
    get "/v1/plans"

    assert_response :unauthorized
    assert_problem "unauthorized"
    assert_equal "This request needs a bearer token issued by this platform's identity service.",
      json_body["detail"],
      "the 401 body must be one fixed sentence. Which of signature, expiry, issuer or audience " \
      "was wrong is not something a caller learns by trying, and `detail` is the one free-text " \
      "field that could carry it."
  end

  # Each of these is a refusal that used to be a 200 on an API that holds payment
  # records. They are named one at a time because "the lock works" is a claim a
  # reader takes on trust and "GET /v1/customers/:id refuses an anonymous caller" is
  # a fact.
  {
    "reading any customer by its uuid" => [ "GET", ->(t) { "/v1/customers/#{t.customer.id}" } ],
    "paging every customer" => [ "GET", ->(_t) { "/v1/customers" } ],
    "writing a customer" => [ "POST", ->(_t) { "/v1/customers" } ],
    "paging every subscription" => [ "GET", ->(_t) { "/v1/subscriptions" } ],
    "reading any subscription" => [ "GET", ->(t) { "/v1/subscriptions/#{t.subscription.id}" } ],
    "cancelling any subscription" => [ "POST", ->(t) { "/v1/subscriptions/#{t.subscription.id}/cancel" } ],
    "moving any subscription onto another plan" => [ "POST", ->(t) { "/v1/subscriptions/#{t.subscription.id}/change_plan" } ],
    "reading any subscription's entitlements" => [ "GET", ->(t) { "/v1/subscriptions/#{t.subscription.id}/entitlements" } ],
    "reading the catalogue" => [ "GET", ->(_t) { "/v1/plans" } ],
    "writing the catalogue" => [ "POST", ->(_t) { "/v1/plans" } ],
    # The two operations the tenancy declaration names as entry points and that the
    # table above did not carry. `PATCH /v1/customers/:id` is the only customer
    # write, and it is a cross-tenant write's only route in; a receipt is the only
    # `/v1` response that is not JSON. Both are already covered by the
    # router-derived loop above — but a named refusal is a fact and a loop is a
    # claim, and `tenancy.yml`'s `no-identity` arm points at the assertion below.
    # Adding a row moves it, so the declaration's line numbers are measured after
    # this insertion rather than before it.
    "patching a customer" => [ "PATCH", ->(t) { "/v1/customers/#{t.customer.id}" } ],
    "reading a receipt" => [ "GET", ->(t) { "/v1/charges/#{t.charge.id}" } ]
  }.each do |what, (method, path)|
    test "lock: #{what} is refused with no token" do
      without_token!
      fixtures = fixtures_for(what)

      send_request(method, path.call(fixtures))

      assert_response :unauthorized, "#{method} #{what} was reachable with no token"
    end
  end

  # --- direction two: everything else still works with no token ---------------

  UNAUTHENTICATED_SURFACE.each do |method, path|
    test "#{method} #{path} is reachable with no token" do
      without_token!

      send_request(method, path)

      refute_includes [ 401, 503 ], response.status,
        "#{method} #{path} answered #{response.status}. It is not a cafaye client surface: an " \
        "uptime monitor has no credential, and the webhook's sender is a processor " \
        "authenticated by signature. A probe that reports 401 or 503 is a probe that reports " \
        "the service as down, and an orchestrator restarts it."
    end
  end

  test "the probes answer their real payloads with no token" do
    without_token!

    get "/healthz"
    assert_response :success

    get "/readyz"
    assert_response :success
  end

  test "the Stripe webhook verifies by signature with no token, and an unsigned one is refused" do
    # The half that matters: the webhook is not merely *reachable* without a token,
    # it still authenticates. A webhook that answered 200 to anything would be a
    # door that a `Bearer` check had merely been added to.
    without_token!
    payload = stripe_fixture("ping")

    post_stripe_webhook(payload)
    assert_response :success

    post StripeWebhookHelpers::STRIPE_WEBHOOK_PATH,
      params: payload,
      headers: { "CONTENT_TYPE" => "application/json", "Stripe-Signature" => "t=1,v1=deadbeef" }
    assert_response :bad_request, "an unsigned webhook was accepted. The signature check is the " \
      "webhook's authentication and a token check is not a substitute for it."
  end

  # --- the refusals that are ours are 503 -------------------------------------

  test "no identity configured locks /v1 with a 503, not a 401 and not a 200" do
    without_token!
    TestSupport::TestIdentity.with_no_configuration do
      get "/v1/customers"

      assert_response :service_unavailable
      assert_problem "unavailable"
    end
  end

  test "an unreachable identity locks /v1 with a 503" do
    TestSupport::TestIdentity.with_verifier(
      TestSupport::TestIdentity.verifier(jwks_source: ->(_url) { raise Errno::ECONNREFUSED })
    ) do
      get "/v1/customers"

      assert_response :service_unavailable
      assert_problem "unavailable"
    end
  end

  # The one that says "locked", not merely "refused". A *valid* token with no
  # identity to check it against must be a 503: answering 401 would tell a caller
  # holding a good credential to go and rotate it, and answering 200 is the failure
  # this whole packet exists to remove.
  test "a valid token is still refused when there is no identity configured" do
    TestSupport::TestIdentity.with_no_configuration do
      get "/v1/customers"

      assert_response :service_unavailable
    end
  end

  test "the 503 body says nothing about which environment variable is missing" do
    TestSupport::TestIdentity.with_no_configuration do
      get "/v1/customers"

      assert_response :service_unavailable
      detail = json_body["detail"]

      refute_match(/BILLING_IDENTITY/, detail,
        "the 503 named a configuration variable. An unauthenticated caller must not be able to " \
        "read this deployment's configuration out of an error body; the cause goes to the log.")
      assert_equal "This service cannot verify a caller right now.", detail
    end
  end

  test "the 503 cause reaches the log with the trace id, because the body will not carry it" do
    TestSupport::TestIdentity.with_no_configuration do
      log = capture_log { get "/v1/customers" }

      assert_response :service_unavailable
      assert_match(/Identity::Unconfigured/, log,
        "the cause did not reach the log. An operator's first question is what they forgot to " \
        "set, and the body deliberately does not answer it.")
      assert_match(/#{trace_id_header}/, log, "the log line carries no trace id, so support cannot " \
        "join it to the response the caller was given")
    end
  end

  test "an unreachable identity does not lock the webhook, which needs no issuer" do
    TestSupport::TestIdentity.with_verifier(
      TestSupport::TestIdentity.verifier(jwks_source: ->(_url) { raise Errno::ECONNREFUSED })
    ) do
      without_token!

      post_stripe_webhook(stripe_fixture("ping"))
      assert_response :success
    end
  end

  # --- the refusals that are the caller's are 401 -----------------------------

  test "a bad token is a 401" do
    with_raw_token("not-a-jwt")

    get "/v1/customers"

    assert_response :unauthorized
  end

  test "an expired token is a 401" do
    with_raw_token(TestSupport::TestIdentity.expired_token)

    get "/v1/customers"

    assert_response :unauthorized
  end

  test "a token signed by a key identity does not publish is a 401" do
    with_raw_token(TestSupport::TestIdentity.foreign_token)

    get "/v1/customers"

    assert_response :unauthorized
  end

  test "a token minted for another service is a 401" do
    with_raw_token(TestSupport::TestIdentity.token(audience: "some-other-service"))

    get "/v1/customers"

    assert_response :unauthorized
  end

  test "a token from another issuer is a 401" do
    with_raw_token(TestSupport::TestIdentity.token(issuer: "https://identity.elsewhere.test"))

    get "/v1/customers"

    assert_response :unauthorized
  end

  test "a non-bearer Authorization header is a 401, not a bypass" do
    [ "Basic dXNlcjpwYXNz", "bearer", "Bearer", "Token abc", TestSupport::TestIdentity.token ].each do |header|
      with_authorization_header(header)

      get "/v1/customers"

      assert_response :unauthorized, "#{header.inspect} was not refused"
    end
  end

  test "the scheme is matched case-insensitively, as RFC 7235 requires" do
    with_authorization_header("bearer #{TestSupport::TestIdentity.token}")

    get "/v1/customers"

    assert_response :success,
      "a lower-case scheme was refused. RFC 7235 says the scheme is compared " \
      "ASCII-case-insensitively, and a client library that lowercases it is not an attacker."
  end

  test "a request carrying two credentials is refused rather than picking one" do
    # Rack joins repeated headers with a comma, so this arrives as one string with a
    # comma in it. Which of two credentials to honour is a question with no safe
    # default, and "the first one" is an authentication bypass with a parser in front.
    with_authorization_header(
      "Bearer #{TestSupport::TestIdentity.token}, Bearer #{TestSupport::TestIdentity.token}"
    )

    get "/v1/customers"

    assert_response :unauthorized
  end

  test "a token carrying no account is a 401, not a request scoped to nothing" do
    with_raw_token(TestSupport::TestIdentity.token(claims: { "account_id" => nil }))

    get "/v1/customers"

    assert_response :unauthorized,
      "\"no account\" and \"an account I could not read\" must not both be answers to the same " \
      "request. Every query on /v1 is scoped by this claim."
  end

  # --- nothing reaches the database before the caller is known -----------------

  test "a refused request reads no customer and writes nothing" do
    without_token!

    assert_no_difference [ "Customer.count", "OutboxEvent.count" ] do
      post "/v1/customers", params: { owner_type: "Account", owner_id: TestSupport::TestIdentity::Account,
        processor: "stripe" }, as: :json
      assert_response :unauthorized
    end
  end

  test "an authenticated request does read the database, so the 401 is not a blanket refusal" do
    customer

    assert_difference [ "Customer.count" ], 0 do
      get "/v1/customers"
    end

    assert_response :success
    assert_equal 1, json_body.fetch("data").size
  end

  # --- the refusals are problem+json, like every other non-2xx ----------------

  test "both locks are problem+json with a trace id, like every other non-2xx here" do
    without_token!
    get "/v1/customers"
    assert_problem "unauthorized"

    TestSupport::TestIdentity.with_no_configuration do
      get "/v1/customers"
      assert_problem "unavailable"
    end
  end

  private
    # The rows the path lambdas above need, built lazily and memoized.
    #
    # Built **inside the test** rather than in the class body, because the table is
    # evaluated as the class is defined and a row created there would be created
    # outside any test's transaction — visible to the other seven parallel workers
    # and rolled back by nobody.
    #
    # `charge` is here because "reading a receipt" is one of the named refusals:
    # the receipt route is the only `/v1` operation whose success response is not
    # JSON, and it is the one the tenancy declaration names as an entry point.
    def fixtures_for(what)
      @fixtures ||= {}
      @fixtures[what] ||= Struct.new(:customer, :subscription, :charge).new(
        customer, subscription, charge
      )
    end

    def send_request(method, path)
      case method
      when "GET" then get path
      when "POST" then post path, params: {}, as: :json
      when "PATCH" then patch path, params: {}, as: :json
      when "DELETE" then delete path
      else raise "this spec does not know how to send #{method}"
      end
    end

    # A row that exists, so "the lock refused it" is a claim about a request that
    # could otherwise have succeeded. Two of them: one for the read assertions and
    # one for the subscription endpoints, and they belong to the *authenticated*
    # account so that a request which did get through would find them.
    def customer
      @customer ||= Customer.create!(
        owner_type: "Account", owner_id: TestSupport::TestIdentity::Account,
        processor: "stripe", processor_customer_id: "cus_FAKElock#{SecureRandom.hex(6)}"
      )
    end

    def subscription
      @subscription ||= Subscription.create!(
        account_id: TestSupport::TestIdentity::Account, customer: customer, plan: plan,
        processor_subscription_id: "sub_FAKElock#{SecureRandom.hex(8)}", status: "active"
      )
    end

    def plan
      @plan ||= Plan.create!(
        name: "Lock probe", slug: "lock-probe-#{SecureRandom.hex(4)}",
        price: Billing::Money.new(1_900, "USD"), interval: "month",
        processor_price_id: "price_FAKElock#{SecureRandom.hex(6)}"
      )
    end

    # A receipt for the caller's own account, so "the lock refused it" is a claim
    # about a request that could otherwise have succeeded. `account_id` is the
    # same account the token names, which is what `Charge.for_account` scopes on.
    def charge
      @charge ||= Charge.create!(
        account_id: TestSupport::TestIdentity::Account, customer: customer,
        processor_charge_id: "ch_FAKElock#{SecureRandom.hex(6)}",
        amount: 1_900, currency: "USD", description: "Lock probe", paid_at: frozen_now
      )
    end
end
