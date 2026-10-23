# frozen_string_literal: true

require_relative "test_helper"

# The verifier's contract, one test per answer a caller can get.
#
# The order of the file is the order of the trust chain: what the token is
# allowed to ask for, then what the key set may say, then what the claims must
# contain, then what the dependency failing looks like. That order is also the
# order the checks happen in, which is the point — a refusal decided in the
# first group costs no network call, and there is a test per group that asserts
# the server was never asked.
class TokenVerifierTest < TestSupport::Test
  KEY = TestSupport::Keys.key("key-1")
  AUDIENCE = "anywaye-services"

  def setup
    super
    @server = TestSupport::JwksServer.new(KEY)
    @verifier = build_verifier
  end

  # --- the happy path ------------------------------------------------------

  def test_a_valid_token_becomes_a_principal
    principal = @verifier.verify!(token)

    assert_equal("usr_01J9Z8QK5M4N7P2R3T6V8W9X0A", principal.subject)
    assert_equal("acc_01J9Z8QK5M4N7P2R3T6V8W9X0A", principal.account_id)
    assert_equal(%w[billing:read billing:write], principal.scopes)
    assert_equal(now + 900, principal.expires_at)
    assert_equal(now, principal.issued_at)
    assert_equal("jti_01J9Z8QK5M4N7P2R3T6V8W9X0A", principal.token_id)
    assert_equal(@server.issuer, principal.issuer)
  end

  def test_a_valid_token_is_fetched_once_and_then_served_from_the_cache
    3.times { @verifier.verify!(token) }

    assert_equal(1, @server.fetch_count)
  end

  def test_audience_may_be_an_array_containing_this_service
    # RFC 7519: `aud` is a string or an array of strings. An issuer that sends
    # an array is not wrong, and refusing it would be a fleet-wide outage for a
    # shape the spec allows.
    issued = access_token(audience: [ "other-service", AUDIENCE ])

    assert_equal(AUDIENCE, @verifier.verify!(issued).audience)
  end

  def test_an_absent_scope_claim_is_an_empty_set_and_not_everything
    # The failure this prevents is the important one: a scope gate that treated
    # "no scopes" as "all scopes" would be a gate with no gate.
    issued = access_token(scopes: nil)
    principal = @verifier.verify!(issued)

    assert_empty(principal.scopes)
    refute(principal.scope?("billing:write"))
  end

  def test_a_scope_gate_answers_on_the_scope_set_alone
    principal = @verifier.verify!(token)

    assert(principal.scope?("billing:write"))
    refute(principal.scope?("billing:delete"))
  end

  # --- the token chooses nothing (no network is spent) ---------------------

  def test_an_unsigned_token_is_refused
    issued = TestSupport::Tokens.unsigned_token(claims, { "alg" => "none", "kid" => KEY.kid })

    assert_raises(Anywaye::Errors::AlgorithmNotAllowed) { @verifier.verify!(issued) }
  end

  def test_an_hs256_token_signed_with_the_public_key_is_refused
    # Algorithm confusion, the other half: talk the verifier into using its RSA
    # key material as an HMAC secret and the signature becomes forgeable by
    # anyone who has read the JWKS, which is public.
    modulus = TestSupport::Keys.public_jwk(KEY.private_key, KEY.kid)["n"]
    issued = TestSupport::Tokens.hs256_token(claims, secret: modulus)

    assert_raises(Anywaye::Errors::AlgorithmNotAllowed) { @verifier.verify!(issued) }
  end

  def test_an_es256_algorithm_is_refused
    # core's conventions allow ES256 and `guard` allows only RS256. This gem
    # matches guard, because widening the set to accept an algorithm no key set
    # publishes buys nothing and widens what a token can ask for. The constant
    # is `ALGORITHMS` and the decision is recorded in anywaye.yml.
    #
    # The header is rewritten rather than re-signed, which is the shape of the
    # attack: a token that says `ES256` in its protected header, carrying a
    # signature that is really RS256, hoping the verifier picks the algorithm
    # from the header. Nothing may accept it, and nothing may fetch a key for
    # it.
    forged = TestSupport::Tokens.with_header(token, "alg" => "ES256")

    assert_raises(Anywaye::Errors::AlgorithmNotAllowed) { @verifier.verify!(forged) }
  end

  def test_a_refused_algorithm_costs_no_outbound_request
    # The reason the algorithm is checked from the protected header, before any
    # key is fetched: a token that names an algorithm we do not accept must not
    # be able to make this process call identity.
    issued = TestSupport::Tokens.unsigned_token(claims, { "alg" => "none", "kid" => KEY.kid })

    assert_raises(Anywaye::Errors::AlgorithmNotAllowed) { @verifier.verify!(issued) }
    assert_equal(0, @server.fetch_count, "a refused algorithm reached the network")
  end

  def test_a_token_naming_no_key_is_refused
    issued = TestSupport::Tokens.signed_token(KEY, claims, { "kid" => nil })

    assert_raises(Anywaye::Errors::UnknownKey) { @verifier.verify!(issued) }
  end

  def test_a_token_that_is_not_a_token_is_refused
    assert_raises(Anywaye::Errors::TokenInvalid) { @verifier.verify!("not-a-jwt") }
  end

  def test_an_empty_token_is_refused
    assert_raises(Anywaye::Errors::TokenInvalid) { @verifier.verify!("") }
  end

  # --- the key set ---------------------------------------------------------

  def test_a_token_signed_by_an_unknown_key_is_refused
    # Signed with the published key under a `kid` the key set does not carry. A
    # different private key would answer the same question at the cost of a
    # second of RSA keygen, and would test something an attacker cannot do —
    # they do not have the signing key at all, which is why the other tests here
    # are about the header rather than the signature.
    unknown = TestSupport::Tokens.signed_token(KEY, claims, { "kid" => "key-not-published" })

    assert_raises(Anywaye::Errors::UnknownKey) { @verifier.verify!(unknown) }
  end

  def test_a_rotated_key_is_picked_up_with_exactly_one_extra_fetch
    @verifier.verify!(token)
    assert_equal(1, @server.fetch_count)

    rotated = TestSupport::Keys.key("key-2")
    @server.publish(KEY, rotated)

    @verifier.verify!(access_token(rotated))

    assert_equal(2, @server.fetch_count, "a rotation must cost one fetch, not a retry loop")
  end

  def test_a_storm_of_unknown_key_ids_does_not_become_a_storm_of_requests
    # The assertion this packet is really about. Ten distinct unknown `kid`s
    # arrive; a correct verifier answers ten refusals and makes at most two
    # outbound requests in the whole window, because the initial load is the
    # only fetch this cache generation buys and the forced refresh is rate
    # limited behind it.
    #
    # Every one of them is signed with the *real* published key under a `kid` it
    # was never published under, because that is the attack: the `kid` is
    # attacker-chosen, and a test that minted ten fresh key pairs would be
    # spending a second of keygen per request to test something that is not
    # what an attacker does.
    10.times do |index|
      ghost = TestSupport::Tokens.signed_token(KEY, claims, { "kid" => "ghost-#{index}" })
      assert_raises(Anywaye::Errors::UnknownKey) { @verifier.verify!(ghost) }
    end

    assert_operator(@server.fetch_count, :<=, 2,
                    "a caller must not be able to aim every request at identity")
  end

  def test_a_repeated_unknown_key_id_makes_no_second_request
    ghost = TestSupport::Tokens.signed_token(KEY, claims, { "kid" => "key-ghost" })
    5.times { assert_raises(Anywaye::Errors::UnknownKey) { @verifier.verify!(ghost) } }

    assert_equal(1, @server.fetch_count)
  end

  def test_a_key_set_that_cannot_be_fetched_is_unavailable_and_not_a_bad_credential
    # The single most important distinction in the file. identity being down is
    # not the caller's token failing, and a 401 here sends an operator to rotate
    # a credential that was fine.
    @server.fail_with(500)

    assert_raises(Anywaye::Errors::JwksUnavailable) { @verifier.verify!(token) }
  end

  def test_an_answer_that_is_not_a_key_set_is_refused
    # A 200 that is a login page: the shape a misconfigured ingress produces.
    @server.serve_garbage

    assert_raises(Anywaye::Errors::JwksUnavailable) { @verifier.verify!(token) }
  end

  def test_a_failed_fetch_falls_back_to_the_keys_this_process_already_held
    # Throwing the cache away on a failed fetch turns a dependency blip into a
    # total authentication outage. A stale key set is worth more than no key
    # set: at worst a key that has since been rotated out still verifies, and
    # the next successful refresh replaces it.
    #
    # The token is long-lived so that advancing the clock past the cache TTL is
    # the only thing that changes: otherwise this test would be asserting that a
    # token stopped working, which is a different and much duller fact.
    issued = access_token(extra: { "exp" => now.to_i + 86_400 })
    @verifier.verify!(issued)
    assert_equal(1, @server.fetch_count)

    advance(3600)
    @server.fail_with(503)

    principal = @verifier.verify!(issued)

    assert_equal("usr_01J9Z8QK5M4N7P2R3T6V8W9X0A", principal.subject)
    assert_equal(2, @server.fetch_count)
  end

  def test_a_successful_verification_after_an_outage_works_without_configuration
    @server.fail_with(500)
    assert_raises(Anywaye::Errors::JwksUnavailable) { @verifier.verify!(token) }

    @server.serve_keys

    assert_equal("usr_01J9Z8QK5M4N7P2R3T6V8W9X0A", @verifier.verify!(token).subject)
  end

  # --- the claims ----------------------------------------------------------

  def test_an_expired_token_is_refused
    issued = access_token(extra: { "exp" => now.to_i - 1 })

    error = assert_raises(Anywaye::Errors::ClaimInvalid) { @verifier.verify!(issued) }
    assert_equal("exp", error.claim)
  end

  def test_a_not_before_in_the_future_is_refused
    issued = access_token(extra: { "nbf" => now.to_i + 60 })

    error = assert_raises(Anywaye::Errors::ClaimInvalid) { @verifier.verify!(issued) }
    assert_equal("nbf", error.claim)
  end

  def test_a_token_from_another_issuer_is_refused
    issued = access_token(extra: { "iss" => "https://identity.elsewhere.test" })

    error = assert_raises(Anywaye::Errors::ClaimInvalid) { @verifier.verify!(issued) }
    assert_equal("iss", error.claim)
  end

  def test_a_token_for_another_audience_is_refused
    # The packet's own words: a token that is valid for a different audience is
    # not valid here. This is the check that stops a courier token being spent at
    # billing's door.
    issued = access_token(audience: "courier")

    error = assert_raises(Anywaye::Errors::ClaimInvalid) { @verifier.verify!(issued) }
    assert_equal("aud", error.claim)
  end

  def test_a_token_with_no_subject_is_refused
    issued = access_token(sub: nil)

    error = assert_raises(Anywaye::Errors::ClaimInvalid) { @verifier.verify!(issued) }
    assert_equal("sub", error.claim)
  end

  def test_a_token_with_no_token_id_is_refused
    # core's docs/openapi-conventions.md lists `jti` among the required claims.
    issued = access_token(token_id: nil)

    error = assert_raises(Anywaye::Errors::ClaimInvalid) { @verifier.verify!(issued) }
    assert_equal("jti", error.claim)
  end

  def test_a_tampered_payload_does_not_verify
    # A caller editing their own `scope` from `billing:read` to `billing:write`.
    forged = TestSupport::Tokens.tampered_payload(token, claims.merge("scopes" => %w[billing:write billing:delete]))

    assert_raises(Anywaye::Errors::SignatureInvalid) { @verifier.verify!(forged) }
  end

  def test_a_token_signed_by_another_key_under_the_published_kid_does_not_verify
    # Rotation, half done: the key set publishes `key-1`, and something signs
    # with a different private key while claiming to be `key-1`. Only the
    # signature check catches this, and it is the check that matters.
    impostor = TestSupport::Keys.key("key-1-impostor")
    issued = TestSupport::Tokens.signed_token(impostor, claims, { "kid" => KEY.kid })

    assert_raises(Anywaye::Errors::SignatureInvalid) { @verifier.verify!(issued) }
  end

  def test_a_scope_claim_of_the_wrong_type_is_refused_rather_than_ignored
    # `scopes: 42` must not become an empty scope set that a caller then reads
    # as "this caller may do nothing" — it must be a refusal, because a claim
    # the issuer meant and this library could not read is a bug on one side or
    # an attack on the other.
    issued = access_token(extra: { "scopes" => 42 })

    assert_raises(Anywaye::Errors::ClaimInvalid) { @verifier.verify!(issued) }
  end

  def test_clock_skew_has_no_leeway_by_default
    # Restrictive default with a stated trade-off: a token one second in the
    # future is refused. A deployment that cannot keep clocks in step says so
    # with `leeway:`, which is one constructor argument rather than a policy
    # buried in the library.
    issued = access_token(extra: { "iat" => now.to_i + 1, "nbf" => now.to_i + 1 })

    assert_raises(Anywaye::Errors::ClaimInvalid) { @verifier.verify!(issued) }
  end

  def test_a_configured_leeway_accepts_a_token_inside_it
    issued = access_token(extra: { "nbf" => now.to_i + 30 })

    assert_kind_of(Anywaye::Principal, build_verifier(leeway: 60).verify!(issued))
  end

  # --- the claim names, which are ambiguous in the fleet -------------------

  def test_the_space_separated_scope_claim_is_read_too
    # core says `scopes` (an array). guard reads `scope` (a space-separated
    # string). Both are accepted and unioned, because a verifier that reads one
    # name and the issuer sends the other produces an empty scope set — a safe
    # failure for a gate, and a silent one for anything that reads the scopes to
    # decide what to render.
    issued = access_token(extra: { "scopes" => nil, "scope" => "billing:read identity:read" })

    assert_equal(%w[billing:read identity:read], @verifier.verify!(issued).scopes)
  end

  def test_both_scope_claims_are_unioned
    issued = access_token(extra: { "scopes" => %w[a], "scope" => "b c" })

    assert_equal(%w[a b c], @verifier.verify!(issued).scopes)
  end

  def test_the_account_claim_is_optional_by_default
    # A library that refused every token without `account_id` would refuse every
    # token `guard` can currently mint, which would make this migration a
    # big-bang cutover instead of a gem.
    principal = @verifier.verify!(access_token(account_id: nil))

    assert_nil(principal.account_id)
  end

  def test_a_service_that_needs_tenancy_can_require_the_account_claim
    verifier = build_verifier(require_account: true)

    assert_raises(Anywaye::Errors::ClaimInvalid) { verifier.verify!(access_token(account_id: nil)) }
  end

  def test_a_numeric_account_claim_is_read_as_a_string
    principal = @verifier.verify!(access_token(account_id: 1234))

    assert_equal("1234", principal.account_id)
  end

  def test_the_claim_names_are_configurable
    verifier = build_verifier(scope_claims: [ "permissions" ], account_claim: "tenant")
    issued = access_token(extra: { "scopes" => nil, "permissions" => %w[invoices:write], "tenant" => "acc_9" })

    principal = verifier.verify!(issued)

    assert_equal(%w[invoices:write], principal.scopes)
    assert_equal("acc_9", principal.account_id)
  end

  # --- the non-raising door ------------------------------------------------

  def test_verify_answers_nil_where_verify_bang_raises
    assert_nil(@verifier.verify(TestSupport::Tokens.unsigned_token(claims, { "alg" => "none" })))
  end

  def test_verify_answers_a_principal_for_a_good_token
    assert_equal("usr_01J9Z8QK5M4N7P2R3T6V8W9X0A", @verifier.verify(token).subject)
  end

  private

  def key(kid)
    TestSupport::Keys.key(kid)
  end

  def build_verifier(**overrides)
    @clock_offset ||= 0
    Anywaye::TokenVerifier.new(**{
      issuer: @server.issuer,
      audience: AUDIENCE,
      clock: -> { now + @clock_offset }
    }.merge(overrides))
  end

  # Moves the injected clock forward. Nothing in this suite sleeps; the clock
  # moves because the test says it does, which is what makes a TTL assertion
  # deterministic instead of a race against a real second ticking over.
  def advance(seconds)
    @clock_offset = (@clock_offset || 0) + seconds
  end

  def token(overrides = {})
    access_token(KEY, **overrides)
  end

  def access_token(signing_key = KEY, **overrides)
    TestSupport::Tokens.access_token(signing_key, issuer: @server.issuer, audience: AUDIENCE, now: now, **overrides)
  end

  def claims
    {
      "iss" => @server.issuer,
      "aud" => AUDIENCE,
      "sub" => "usr_01J9Z8QK5M4N7P2R3T6V8W9X0A",
      "exp" => now.to_i + 900,
      "iat" => now.to_i,
      "jti" => "jti_01J9Z8QK5M4N7P2R3T6V8W9X0A",
      "account_id" => "acc_01J9Z8QK5M4N7P2R3T6V8W9X0A",
      "scopes" => %w[billing:read billing:write]
    }
  end
end
