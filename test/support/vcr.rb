require "vcr"

# The recording that stands between this suite and the internet.
#
# ## The rule
#
# A test may reach Stripe only through a recording of Stripe. `record: :once`
# means the first run — the one where `test/services/processor/
# stripe_client_live_test.rb` was recorded against the real test-mode API —
# wrote the cassettes, and every run after it replays those bytes with the
# network **forbidden**. So the suite is hermetic (no key, no socket, no
# flake) while the request shapes it exercises are the processor's own
# answers rather than this repository's guess at them.
#
# `allow_http_connections_when_no_cassette = false` is the half that makes
# "hermetic" a fact rather than a hope: a test that forgot its cassette does
# not quietly reach the internet, it fails.
#
# ## Matching, and why the body is one of the keys
#
# Method, URI and body. Two of the five requests carry amounts of meaning in
# their bodies (a price id, `proration_behavior`), and matching on the URI
# alone would let a changed body replay an unchanged recording — green over
# the one thing the spec is about. The spec therefore pins every input to a
# literal, and a changed literal is a cassette miss rather than a false pass.
#
# ## What is filtered, and why the filter is by VALUE
#
# The key travels in an `Authorization` header the `stripe` gem sets per
# request; `filter_sensitive_data` replaces the VALUE wherever it appears —
# header or body — so a recording cannot carry it even if the gem moves the
# key to a different field. The webhook secret is filtered for the same
# reason: this repository already treats it as material a test must never
# hold (`test/integration/secrets_do_not_leak_test.rb`).
VCR.configure do |config|
  config.cassette_library_dir = "test/cassettes"
  config.hook_into :webmock

  config.filter_sensitive_data("<STRIPE_API_KEY>") { ENV["STRIPE_API_KEY"] }
  config.filter_sensitive_data("<STRIPE_SECRET_KEY>") { ENV["STRIPE_SECRET_KEY"] }
  config.filter_sensitive_data("<STRIPE_WEBHOOK_SECRET>") { ENV["STRIPE_WEBHOOK_SECRET"] }

  config.allow_http_connections_when_no_cassette = false

  config.default_cassette_options = {
    record: :once,
    match_requests_on: [ :method, :uri, :body ]
  }
end
