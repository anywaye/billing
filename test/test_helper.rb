ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "openssl"

# Spec helpers. Plain modules, no framework gem.
Dir[Rails.root.join("test/support/**/*.rb")].sort.each { |file| require file }

# The test database's account boundary, installed before any test runs.
#
# Rails builds this database from `db/schema.rb`, which cannot express a policy, a
# row level security bit, a function or a grant — so the three account-scoped
# tables arrive with no boundary at all, and `test/tenancy/database_isolation_test.rb`,
# which is the only place the boundary is proven, would be asserting against a
# database where every denial is absent (and where "zero rows" means the same thing
# for a missing policy as for a working one).
#
# `Tenancy::Substrate.install!` runs the SAME two DDL files the migration runs, as
# the `billing` role — the role that owns those tables in production, and the only
# role whose ownership makes the owner arm of those assertions mean anything. It is
# the same install the rake task runs after `db:schema:load`, so there is one
# implementation of "install the boundary" and three callers.
Tenancy::Substrate.install!

# Fake collaborators for a single test.
#
# minitest 6 dropped `Object#stub` (it moved to the separate minitest-mock gem,
# which this service does not depend on), so we use the stub registry that
# ActiveSupport already keeps for time helpers. Stubs are also removed
# automatically in `after_teardown`; the block form below restores them sooner,
# so a failing assertion cannot leak a stub into the next test.
module StubbedCollaborators
  # Makes `ActiveRecord::Base.lease_connection` return `connection` for the
  # duration of the block. Used to simulate a database that is down.
  def with_lease_connection(connection)
    simple_stubs.stub_object(ActiveRecord::Base, :lease_connection) { connection }
    yield
  ensure
    simple_stubs.unstub_all!
  end

  # Sets environment variables for the duration of the block and puts the
  # previous values back, including "was not set at all". A `nil` value deletes
  # the key, which is how a test asks for "the secret is not configured".
  def with_env(variables)
    previous = variables.keys.to_h { |key| [ key, ENV[key] ] }
    variables.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end

# Signs a webhook body the way Stripe signs one, so the suite exercises the real
# verification path instead of a stubbed one.
#
# The scheme is Stripe's, not ours: `t=<unix seconds>,v1=<hex>` where the HMAC is
# SHA-256 over "<timestamp>.<raw body>" keyed with the endpoint's signing secret.
# Fixtures are committed JSON; the secret below is a local constant that exists
# only in this suite and is a credential for nothing.
module StripeWebhookHelpers
  WEBHOOK_SECRET = "whsec_test_only_signing_secret"

  # The path in `openapi/v1.yaml` and in the routes. Duplicated here on purpose:
  # the integration test asserts the two agree, so a change to one without the
  # other fails instead of passing.
  STRIPE_WEBHOOK_PATH = "/v1/webhooks/stripe"

  def stripe_fixture(name)
    File.read(Rails.root.join("test/fixtures/stripe", "#{name}.json"))
  end

  def stripe_signature(payload, secret: WEBHOOK_SECRET, timestamp: Time.now.to_i)
    digest = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{payload}")
    "t=#{timestamp},v1=#{digest}"
  end

  # Posts a body to the Stripe webhook exactly as Stripe would: the raw bytes,
  # `application/json`, and a `Stripe-Signature` header over those bytes.
  #
  # The path is the literal documented path rather than the route helper, so
  # renaming the route cannot quietly leave these tests passing against a URL
  # that is no longer served.
  def post_stripe_webhook(payload, secret: WEBHOOK_SECRET, timestamp: Time.now.to_i, path: STRIPE_WEBHOOK_PATH)
    post path,
      params: payload,
      headers: {
        "CONTENT_TYPE" => "application/json",
        "Stripe-Signature" => stripe_signature(payload, secret: secret, timestamp: timestamp)
      }
  end
end

# The Stripe signing secret for the suite. Set once, here, rather than in every
# test: it is a constant, not a secret, and the test that needs it *absent*
# deletes it with `with_env`.
ENV["STRIPE_WEBHOOK_SECRET"] = StripeWebhookHelpers::WEBHOOK_SECRET

# The identity the suite verifies against, installed once. `/v1` requires a token,
# so a suite that ran with no identity configured would be a suite where every
# request is a 503 and every assertion about the surface is about the lock rather
# than about billing. The specs that prove the lock (`test/authentication/`) delete
# the configuration with `with_env` and put it back.
TestSupport::TestIdentity.install_default!

module ActiveSupport
  class TestCase
    include StubbedCollaborators
    include StripeWebhookHelpers
    include TestSupport::FrozenClock
    include TestSupport::ApiHelpers

    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # The boundary again, in each worker's OWN database.
    #
    # Rails creates `…_test_0` … `…_test_7` and loads `db/schema.rb` into them in the
    # PARENT process, before forking — so the install at the top of this file reached
    # only the primary test database, and every worker's database had the three
    # tables and no `cafaye` schema at all. Measured, with that install alone: 285 of
    # 1256 tests failed with `schema "cafaye" does not exist`, which is a missing
    # boundary reported as a missing function. `parallelize_setup` is the
    # after-fork hook, so it runs in the worker, against the worker's connection.
    parallelize_setup { Tenancy::Substrate.install! }

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
