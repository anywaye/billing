ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "openssl"

Dir[Rails.root.join("test/support/**/*.rb")].sort.each { |file| require file }

Tenancy::Substrate.install!

module StubbedCollaborators
  def with_lease_connection(connection)
    simple_stubs.stub_object(ActiveRecord::Base, :lease_connection) { connection }
    yield
  ensure
    simple_stubs.unstub_all!
  end

  def with_env(variables)
    previous = variables.keys.to_h { |key| [ key, ENV[key] ] }
    variables.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end

module StripeWebhookHelpers
  WEBHOOK_SECRET = "whsec_test_only_signing_secret"

  STRIPE_WEBHOOK_PATH = "/v1/webhooks/stripe"

  def stripe_fixture(name)
    File.read(Rails.root.join("test/fixtures/stripe", "#{name}.json"))
  end

  def stripe_signature(payload, secret: WEBHOOK_SECRET, timestamp: Time.now.to_i)
    digest = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{payload}")
    "t=#{timestamp},v1=#{digest}"
  end

  def post_stripe_webhook(payload, secret: WEBHOOK_SECRET, timestamp: Time.now.to_i, path: STRIPE_WEBHOOK_PATH)
    post path,
      params: payload,
      headers: {
        "CONTENT_TYPE" => "application/json",
        "Stripe-Signature" => stripe_signature(payload, secret: secret, timestamp: timestamp)
      }
  end
end

ENV["STRIPE_WEBHOOK_SECRET"] = StripeWebhookHelpers::WEBHOOK_SECRET

TestSupport::TestIdentity.install_default!

module ActiveSupport
  class TestCase
    include StubbedCollaborators
    include StripeWebhookHelpers
    include TestSupport::FrozenClock
    include TestSupport::ApiHelpers

    parallelize(workers: :number_of_processors)

    parallelize_setup { Tenancy::Substrate.install! }

    fixtures :all
  end
end
