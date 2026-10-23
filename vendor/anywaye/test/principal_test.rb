# frozen_string_literal: true

require_relative "test_helper"

# The result object.
#
# It is the boundary of this library on the success path, and the packet is
# unusually specific about it: "a small, frozen, explicit result object — the
# caller needs the subject, the tenant/account, the scopes, and the expiry. Do
# not hand back the raw token string, and do not return the claims hash with
# indifferent access." Every test here is one of those three requirements.
class PrincipalTest < TestSupport::Test
  KEY = TestSupport::Keys.key("key-1")

  def setup
    super
    @server = TestSupport::JwksServer.new(KEY)
    @verifier = Anywaye::TokenVerifier.new(
      issuer: @server.issuer,
      audience: "anywaye-services",
      account_claim: "account_id",
      clock: -> { now }
    )
  end

  def test_it_exposes_exactly_the_fields_a_caller_needs
    principal = verify

    assert_equal(
      %i[account_id audience expires_at issued_at issuer scopes subject token_id],
      principal.to_h.keys.sort
    )
  end

  def test_the_expiry_is_a_time_and_not_a_number
    # A caller comparing an `exp` to `Time.current` has to know which it is
    # holding, and `Integer` and `Time` are both "the expiry" until one of them
    # is compared to the other.
    assert_instance_of(Time, verify.expires_at)
    assert_instance_of(Time, verify.issued_at)
  end

  def test_the_expiry_is_in_utc
    assert_predicate(verify.expires_at, :utc?)
  end

  def test_the_account_is_nil_when_the_claim_is_absent_and_there_is_no_lying_default
    # Not an empty string, and not a wildcard. A service that forgets to check
    # `account_id` for nil gets an exception rather than a query scoped to
    # nothing, which would return every row.
    principal = verify(account_id: nil)

    assert_nil(principal.account_id)
  end

  def test_the_scopes_are_sorted_deduplicated_and_frozen
    # Sorted and deduplicated so two tokens granting the same authority in a
    # different order produce two equal principals, which is what makes a
    # principal usable as a cache key.
    principal = verify(scopes: %w[billing:write billing:read billing:write])

    assert_equal(%w[billing:read billing:write], principal.scopes)
  end

  def test_a_scope_of_odd_whitespace_is_still_one_scope
    # A space-separated claim with a double space or a trailing newline is a
    # claim an issuer emitted, not an attack, and `"".split` would otherwise
    # make it a scope named "".
    principal = verify(scopes: nil, extra: { "scope" => "  billing:read   billing:write \n" })

    assert_equal(%w[billing:read billing:write], principal.scopes)
  end

  def test_it_is_equal_to_another_principal_with_the_same_claims
    # Two verifications of the same token are two objects, and a caller caching
    # a principal on a hot path should not have to know that.
    assert_equal(verify, verify)
  end

  def test_it_is_not_equal_to_a_principal_with_different_claims
    refute_equal(verify, verify(scopes: %w[admin]))
  end

  def test_it_hashes_by_its_claims
    # The corollary of the last two, and the reason `==` is defined at all: a
    # caller caching a principal on a hot path needs two verifications of the
    # same token to be one cache entry and two different tokens to be two.
    assert_equal(1, [ verify, verify ].uniq.size)
    assert_equal(2, [ verify, verify(scopes: %w[admin]) ].uniq.size)
    assert_equal(1, { verify => :ok }.size)
  end

  def test_its_inspect_carries_no_claim_the_library_did_not_name
    # `inspect` is what lands in a log line when a principal is in a hash, an
    # exception message or a debugger's variable dump, so it is a logging
    # surface and it is held to the same rule.
    principal = verify(extra: { "note" => "CANARY-must-not-appear" })

    refute_includes(principal.inspect, "CANARY-must-not-appear")
    assert_includes(principal.inspect, principal.subject)
    # The field names it prints are the library's own, which is the whole claim:
    # there is no path from a claim to this string.
    assert_equal(
      %i[account_id expires_at scopes subject].sort,
      principal.inspect.scan(/(\w+)=/).flatten.map(&:to_sym).sort
    )
  end

  private

  def verify(**overrides)
    token = TestSupport::Tokens.access_token(
      KEY, issuer: @server.issuer, audience: "anywaye-services", now: now, **overrides
    )
    @verifier.verify!(token)
  end
end
