# frozen_string_literal: true

require_relative "test_helper"

# THE CANARY.
#
# This file is the packet's security constraint, so it is worth being explicit
# about what is being claimed.
#
# A token is a credential. Everything inside one — the compact serialisation, the
# `sub`, whatever else identity has decided to put in there — is text that ends
# up somewhere it should not. Adding verification adds a new destination for
# exactly that text: this library's logger, and the exception messages a host
# application logs, prints into a `problem+json` body, or pastes into an issue.
# So "we do not log the token" has to become "there is no path from a token to a
# log line", and the only thing that survives future changes is a test that fails
# when that path appears.
#
# The canary is a unique string placed in a claim, and the assertion is on the
# **rendered output of the logger sink** — every line, at every level, as one
# string. Asserting key by key would only prove a filter catches the names
# somebody already thought of.
#
# It is asserted both ways, and the order matters. First that the canary is
# genuinely in the input, so the test cannot pass vacuously — an empty log and a
# verifier that never saw the claim look identical from one side. Then that it is
# absent from the output. Then the specific dangerous properties, because
# "the canary is absent" and "the key material is absent" are different claims
# and only the first is about a value the attacker chose.
#
# The method here is muse's, from `muse/tests/test_trace_propagation.py`: a
# canary in the input, asserted *present* first, and a whole-payload assertion
# rather than a per-field one.
class CanaryTest < TestSupport::Test
  # A string that must not survive anywhere. It appears in a claim of a token
  # this process really signs and really verifies, and nowhere else, so a hit in
  # the output is unambiguous.
  CANARY = "CANARY-4b1e9a02-DO-NOT-LOG-THIS"

  KEY = TestSupport::Keys.key("key-1")
  AUDIENCE = "anywaye-services"

  def setup
    super
    @server = TestSupport::JwksServer.new(KEY)
    @verifier = Anywaye::TokenVerifier.new(issuer: @server.issuer, audience: AUDIENCE, clock: -> { now })
  end

  def test_a_claim_value_never_reaches_a_log_line_on_a_successful_verification
    token = token_with_canary

    # The request really did carry the canary, or the test proves nothing.
    assert_equal(CANARY, claims_of(token)["note"], "the canary was not in the input token")

    @verifier.verify!(token)

    assert_empty(logged_output, "a canary claim reached the log on the success path")
  end

  def test_a_claim_value_never_reaches_a_log_line_on_a_refusal
    token = token_with_canary({ "iss" => "https://identity.elsewhere.test" })

    assert_equal(CANARY, claims_of(token)["note"], "the canary was not in the input token")
    assert_raises(Anywaye::Errors::ClaimInvalid) { @verifier.verify!(token) }

    assert_empty(logged_output, "a canary claim reached the log on the refusal path")
  end

  def test_a_claim_value_never_reaches_a_log_line_when_the_key_set_is_unavailable
    token = token_with_canary
    @server.fail_with(500)

    assert_equal(CANARY, claims_of(token)["note"], "the canary was not in the input token")
    assert_raises(Anywaye::Errors::JwksUnavailable) { @verifier.verify!(token) }

    assert_empty(logged_output, "a canary claim reached the log on the dependency-failure path")
  end

  def test_the_token_itself_never_reaches_a_log_line
    token = token_with_canary

    @verifier.verify!(token)

    # The whole compact serialisation, not a prefix of it. A truncation rule is
    # not a redaction rule: the first eight characters of a bearer token are
    # eight characters of a bearer token, and "we only log the first eight" is
    # the reasoning that produces a credential in a log index. The rule this
    # library follows is the simpler one — none of it, ever — and this
    # assertion is what holds it there.
    assert_empty(logged_output)
  end

  def test_key_material_never_reaches_a_log_line
    modulus = TestSupport::Keys.public_jwk(KEY.private_key, KEY.kid)["n"]
    exponent = TestSupport::Keys.public_jwk(KEY.private_key, KEY.kid)["e"]

    @verifier.verify!(token_with_canary)

    refute_includes(logged_output, modulus, "the RSA modulus reached the log")
    refute_includes(logged_output, exponent, "the RSA exponent reached the log")
  end

  def test_a_refusal_message_carries_neither_the_token_nor_a_claim
    token = token_with_canary({ "aud" => "courier" })

    error = assert_raises(Anywaye::Errors::ClaimInvalid) { @verifier.verify!(token) }

    refute_includes(error.message, CANARY)
    refute_includes(error.message, token)
    # The claim *name* is safe and useful — it is a closed vocabulary of RFC
    # names, not a value — and it is the one thing the message does say.
    assert_equal("aud", error.claim)
  end

  def test_a_backtrace_carries_neither_the_token_nor_a_claim
    # A backtrace is a thing people paste into an issue. The `jwt` gem's own
    # failures are rescued and re-raised as this library's classes, so nothing a
    # third-party message says about a token reaches the stack.
    token = token_with_canary({ "iss" => "https://identity.elsewhere.test" })

    error = assert_raises(Anywaye::Errors::ClaimInvalid) { @verifier.verify!(token) }
    full = error.full_message(highlight: false, order: :top)

    refute_includes(full, CANARY)
    refute_includes(full, token)
  end

  def test_an_unknown_key_is_refused_without_naming_the_key_or_the_key_id
    # The `kid` is attacker-chosen, so it is not a thing to write down either:
    # a key id is a substring of a token's own header, and a log full of them
    # is a log full of attacker-chosen strings next to the fact that a key set
    # was consulted.
    ghost = TestSupport::Tokens.signed_token(KEY, claims_for_building, { "kid" => "key-ghost" })

    error = assert_raises(Anywaye::Errors::UnknownKey) { @verifier.verify!(ghost) }

    refute_includes(error.message, "key-ghost")
    refute_includes(logged_output, ghost)
    assert_empty(logged_output)
  end

  # --- the unit-level statements behind the integration assertion ------------

  def claims_for_building
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

  def test_a_token_object_will_not_print_itself
    # The mechanism, stated at the unit level so the integration test above is
    # not resting on "this library happened not to log one today".
    #
    # A String subclass would leak through every C-level string operation and
    # through `to_s`, `%s`, f-strings, `inspect` and `Array#join` — which is
    # exactly the path an exception message takes. So this is a plain object
    # that is not a String and defines no implicit conversion to one.
    token = Anywaye::Token.new("a-real-token-value")

    assert_equal("[REDACTED]", token.to_s)
    assert_equal("[REDACTED]", "#{token}")
    assert_equal("[REDACTED]", format("%s", token))
    assert_equal("[REDACTED]", [ token ].join(","))
    assert_match(/REDACTED/, token.inspect)
    # No implicit conversion to a String, which is the property that makes every
    # one of the lines above hold: with a `to_str` or a `String` superclass, a
    # coercion somewhere in an exception path would put the real value back.
    refute_respond_to(token, :to_str)
    refute_operator(token, :is_a?, String)
  end

  def test_a_token_object_reveals_only_through_an_explicit_call
    # Every read of the raw value is greppable, which is the property that makes
    # a review of "where is the credential read" possible.
    token = Anywaye::Token.new("a-real-token-value")

    assert_equal("a-real-token-value", token.reveal)
    assert_equal(1, token.class.instance_methods(false).count { |name| name == :reveal })
  end

  def test_a_token_fingerprint_does_not_carry_the_token
    # A fingerprint exists so two log lines can be correlated to one credential
    # without either of them being usable. It is a truncated SHA-256 of a
    # high-entropy serialisation, so it cannot be inverted — and the library
    # writes it nowhere, so the question does not arise on any path this gem
    # owns. It is available to a caller who has decided they need it.
    token = Anywaye::Token.new("a-real-token-value")

    refute_includes(token.fingerprint, "a-real")
    assert_equal(16, token.fingerprint.length)
    assert_equal(token.fingerprint, Anywaye::Token.new("a-real-token-value").fingerprint)
    refute_equal(token.fingerprint, Anywaye::Token.new("another-value").fingerprint)
  end

  def test_a_principal_cannot_reach_a_claim_the_library_did_not_name
    # The other half of "never log a claim": a caller must not be handed the
    # whole claims hash to log by accident. There is no `[]`, no `to_h` of the
    # claims, and no accessor for anything this file does not name.
    principal = @verifier.verify!(token_with_canary)

    refute_respond_to(principal, :[])
    refute_respond_to(principal, :claims)
    refute_includes(principal.to_h.values.map(&:to_s), CANARY)
    refute_includes(principal.to_h.keys.map(&:to_s), CANARY)
  end

  def test_a_principal_is_frozen_all_the_way_down
    principal = @verifier.verify!(token_with_canary)

    assert_predicate(principal, :frozen?)
    assert_predicate(principal.scopes, :frozen?)
    assert_predicate(principal.scopes.first, :frozen?)
    assert_predicate(principal.subject, :frozen?)
    # No writer at all, which is a stronger statement than "a writer that
    # raises": there is no assignment that can widen this object.
    assert_raises(NoMethodError) { principal.subject = "someone-else" }
    assert_raises(FrozenError) { principal.scopes << "admin" }
  end

  private

  def token_with_canary(claim_overrides = {})
    TestSupport::Tokens.access_token(
      KEY,
      issuer: @server.issuer,
      audience: AUDIENCE,
      now: now,
      extra: { "note" => CANARY }.merge(claim_overrides)
    )
  end

  # The claims of a token, read without verification. This test is asserting its
  # own premise — that the canary really is in the input — so it is allowed to
  # decode without a signature check, and it is the only place in this
  # repository that does.
  def claims_of(token)
    payload = token.split(".")[1]
    JSON.parse(Base64.urlsafe_decode64(payload + ("=" * ((4 - (payload.length % 4)) % 4))))
  end
end
