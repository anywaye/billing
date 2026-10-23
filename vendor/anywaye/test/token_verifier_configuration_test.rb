# frozen_string_literal: true

require_relative "test_helper"

# Configuration is checked when the verifier is built, not on the first request.
#
# `guard` states the rule and the reason in its AGENTS.md: "Invalid config is
# an error, not a fallback … a typo in an environment variable that only
# surfaces as a 503 on every request is a typo nobody finds." A verifier that
# accepts `jwks_url: "identity.internal"` and only finds out when it cannot
# parse it is a verifier whose first real user is the one who pays.
class TokenVerifierConfigurationTest < TestSupport::Test
  def build(**overrides)
    Anywaye::TokenVerifier.new(**{ issuer: "https://identity.anywaye.com", audience: "anywaye-services" }.merge(overrides))
  end

  def test_an_issuer_that_is_not_a_url_is_refused
    error = assert_raises(Anywaye::Errors::ConfigurationError) { build(issuer: "identity.internal") }

    assert_match(/issuer/, error.message)
  end

  def test_an_issuer_with_a_path_is_refused
    # The JWKS path is appended to the issuer, so a base with a path of its own
    # would put the key set somewhere nobody is serving it from.
    assert_raises(Anywaye::Errors::ConfigurationError) { build(issuer: "https://identity.anywaye.com/tenant-a") }
  end

  def test_a_trailing_slash_on_the_issuer_is_dropped
    # It is what an operator types out of habit, and keeping it would join into
    # `https://identity.anywaye.com//.well-known/jwks.json`.
    verifier = build(issuer: "https://identity.anywaye.com/")

    assert_equal("https://identity.anywaye.com", verifier.issuer)
    assert_equal("https://identity.anywaye.com/.well-known/jwks.json", verifier.jwks_url)
  end

  def test_a_plain_http_key_set_url_is_refused_off_loopback
    # guard's verifier accepts `http:` for any host, which means a misconfigured
    # `IDENTITY_ISSUER` silently downgrades key distribution to plaintext. Here
    # http is only allowed to loopback, which is what a developer's compose
    # stack needs and nothing else does.
    error = assert_raises(Anywaye::Errors::ConfigurationError) { build(issuer: "http://identity.anywaye.com") }

    assert_match(/https/, error.message)
  end

  def test_a_plain_http_key_set_url_is_allowed_on_loopback
    assert_equal("http://127.0.0.1:9292", build(issuer: "http://127.0.0.1:9292").issuer)
  end

  def test_an_explicit_key_set_url_may_be_anywhere_https
    verifier = build(issuer: "https://identity.anywaye.com", jwks_url: "https://auth.anywaye.com/jwks")

    assert_equal("https://auth.anywaye.com/jwks", verifier.jwks_url)
  end

  def test_an_explicit_key_set_url_in_plain_http_is_refused_off_loopback
    assert_raises(Anywaye::Errors::ConfigurationError) do
      build(issuer: "https://identity.anywaye.com", jwks_url: "http://auth.anywaye.com/jwks")
    end
  end

  def test_an_empty_audience_is_refused
    # A verifier with an empty audience accepts any `aud`, which is not a
    # configuration, it is a missing one.
    assert_raises(Anywaye::Errors::ConfigurationError) { build(audience: "  ") }
  end

  def test_a_zero_cache_ttl_is_refused
    # A TTL of zero means "never cache", which on a fleet behind guard is a
    # request per request to identity.
    error = assert_raises(Anywaye::Errors::ConfigurationError) { build(jwks_cache_ttl: 0) }

    assert_match(/jwks_cache_ttl/, error.message)
  end

  def test_a_negative_timeout_is_refused
    assert_raises(Anywaye::Errors::ConfigurationError) { build(jwks_timeout: -1) }
  end

  def test_a_zero_refresh_interval_is_refused
    # The refresh interval is the bound on the storm. Zero removes the bound.
    assert_raises(Anywaye::Errors::ConfigurationError) { build(min_refresh_interval: 0) }
  end

  def test_a_zero_unknown_kid_ttl_is_refused
    # Zero would mean the negative cache never holds, which is the same
    # unbounded refresh as not having one.
    assert_raises(Anywaye::Errors::ConfigurationError) { build(unknown_kid_ttl: 0) }
  end

  def test_a_negative_leeway_is_refused
    assert_raises(Anywaye::Errors::ConfigurationError) { build(leeway: -5) }
  end

  def test_an_empty_scope_claim_list_is_refused
    # A verifier that reads no scope claim cannot tell a scoped token from an
    # unscoped one, and a service that asked for a scope gate would get one
    # that passes everything.
    assert_raises(Anywaye::Errors::ConfigurationError) { build(scope_claims: []) }
  end

  def test_an_empty_account_claim_name_is_refused
    assert_raises(Anywaye::Errors::ConfigurationError) { build(account_claim: "") }
  end

  def test_a_valid_configuration_builds
    verifier = build

    assert_equal("anywaye-services", verifier.audience)
    assert_predicate(verifier, :configured?)
  end

  def test_the_defaults_are_the_documented_ones
    verifier = build

    assert_equal(300, verifier.jwks_cache_ttl)
    assert_equal(5, verifier.jwks_timeout)
    assert_equal(30, verifier.unknown_kid_ttl)
    assert_equal(30, verifier.min_refresh_interval)
    assert_equal(0, verifier.leeway)
    assert_equal([ "RS256" ], Anywaye::TokenVerifier::ALGORITHMS)
  end
end
