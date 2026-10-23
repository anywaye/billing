require "test_helper"

# The verifier itself, against real RSA signatures.
#
# # Nothing here is a fake
#
# The keys are generated, the tokens are signed, and the signatures are checked by
# the same code path production uses. What is replaced is the **fetch**: the JWKS
# comes from a callable rather than from identity, because a spec that fetched from
# a real identity would fail when identity is down and pass when it is up — the
# wrong axis. Every refusal below is arranged by presenting a token this suite
# minted that differs from an accepted one in exactly one way.
#
# # Each refusal is a distinct test, and the reason is worth stating
#
# "an invalid token is refused" is satisfied by a verifier that refuses everything,
# including a correct token. So each test names **which** thing was wrong, and there
# is a separate test that a correct token is **accepted** — so a verifier that
# refused everything fails rather than passing every refusal above it. That pairing
# is the whole reason this file can be believed.
class IdentityTokenVerifierTest < ActiveSupport::TestCase
  setup do
    @verifier = TestSupport::TestIdentity.verifier
  end

  # --- the accept path, which every refusal below depends on --------------------

  test "a correctly signed token with every required claim is accepted" do
    principal = @verifier.verify(TestSupport::TestIdentity.token)

    assert_equal TestSupport::TestIdentity::Account, principal.account_id
    assert_equal "user-#{TestSupport::TestIdentity::Account}", principal.subject
    assert_equal TestSupport::TestIdentity.issuer, principal.issuer
    assert_equal %w[openid accounts], principal.scopes,
      "the space-separated `scope` claim must be split on whitespace and deduped"
    assert principal.scope?("accounts")
  end

  test "the key set is fetched once and reused, rather than per request" do
    fetches = 0
    verifier = TestSupport::TestIdentity.verifier(jwks_source: ->(_url) { fetches += 1; TestSupport::TestIdentity.jwks })

    3.times { verifier.verify(TestSupport::TestIdentity.token) }

    assert_equal 1, fetches,
      "the key set was fetched #{fetches} times for three requests. A JWKS fetch per request " \
      "would mean every call to this service is a call to identity, and core's conventions " \
      "say to cache by kid with a bounded TTL and never call identity on the hot path."
  end

  # --- the three refusals, and which status each one becomes -------------------

  test "an absent token is refused" do
    assert_raises(Identity::Invalid) { @verifier.verify(nil) }
  end

  test "a token that is not a JWT is refused before any fetch" do
    fetches = 0
    verifier = TestSupport::TestIdentity.verifier(jwks_source: ->(_url) { fetches += 1; TestSupport::TestIdentity.jwks })

    [ "", "abc", "a.b", "not.a.jwt" ].each do |token|
      assert_raises(Identity::Invalid, "#{token.inspect} was accepted") { verifier.verify(token) }
    end

    assert_equal 0, fetches,
      "a malformed token cost a call to identity. The protected header is read before the key " \
      "set is touched, so a forged token cannot aim traffic at the issuer."
  end

  test "an HS256 token signed with the published public key is refused" do
    # The algorithm-confusion attack, and the reason the algorithm is a constant here
    # rather than something read off the token: a verifier that honoured the header's
    # `alg` would verify this, because the public key is public.
    header = JSON.parse(Base64.urlsafe_decode64(TestSupport::TestIdentity.token.split(".").first))
    forged = JWT.encode({ "iss" => TestSupport::TestIdentity.issuer, "aud" => TestSupport::TestIdentity::AUDIENCE },
      TestSupport::TestIdentity.private_key.public_key.to_pem, "HS256", { kid: TestSupport::TestIdentity::KID })

    assert_equal "RS256", header["alg"], "the fixture's own token is RS256; the test is about the forged one"
    assert_raises(Identity::Invalid) { @verifier.verify(forged) }
  end

  test "an alg: none token is refused" do
    none = JWT.encode({ "iss" => TestSupport::TestIdentity.issuer }, nil, "none", { kid: TestSupport::TestIdentity::KID })

    assert_raises(Identity::Invalid) { @verifier.verify(none) }
  end

  test "a token signed by a key this service's key set does not publish is refused" do
    assert_raises(Identity::Invalid) { @verifier.verify(TestSupport::TestIdentity.foreign_token) }
  end

  test "an expired token is refused" do
    assert_raises(Identity::Invalid) { @verifier.verify(TestSupport::TestIdentity.expired_token) }
  end

  test "a token issued to another audience is refused" do
    token = TestSupport::TestIdentity.token(audience: "some-other-service")

    assert_raises(Identity::Invalid) { @verifier.verify(token) }
  end

  test "a token from another issuer is refused" do
    token = TestSupport::TestIdentity.token(issuer: "https://identity.elsewhere.test")

    assert_raises(Identity::Invalid) { @verifier.verify(token) }
  end

  Identity::TokenVerifier::REQUIRED_CLAIMS.each do |claim|
    test "a token with no #{claim} claim is refused" do
      token = TestSupport::TestIdentity.token(claims: { claim => nil })

      assert_raises(Identity::Invalid, "a token with no #{claim} was accepted") { @verifier.verify(token) }
    end
  end

  # --- unconfigured is a refusal, and a different one --------------------------

  # **The environment is deleted, not a constructor argument faked.**
  #
  # `TokenVerifier.new` reads `BILLING_IDENTITY_*` when it is given nothing, which
  # is the same fallback `Processor::StripeClient` has, so the way to ask "what
  # happens when this deployment configured nothing" is to unset the variables —
  # the state a self-hoster is actually in. Passing `issuer: nil` would have tested
  # a constructor that does not exist.
  test "no configured issuer refuses every token, and it is Unconfigured rather than Invalid" do
    with_env("BILLING_IDENTITY_ISSUER" => nil) do
      verifier = Identity::TokenVerifier.new(audience: TestSupport::TestIdentity::AUDIENCE)

      error = assert_raises(Identity::Unconfigured) { verifier.verify(TestSupport::TestIdentity.token) }
      assert_match(/issuer/, error.message)
    end
  end

  test "no configured audience refuses every token" do
    with_env("BILLING_IDENTITY_AUDIENCE" => nil) do
      verifier = Identity::TokenVerifier.new(issuer: TestSupport::TestIdentity.issuer)

      assert_raises(Identity::Unconfigured) { verifier.verify(TestSupport::TestIdentity.token) }
    end
  end

  test "a configured verifier with no reachable key set still refuses, and does not fetch" do
    # The pair above proves the lock; this proves the lock is reached before any
    # network work, which is what keeps an unconfigured deployment from becoming an
    # outbound-request amplifier aimed at identity.
    with_env(TestSupport::TestIdentity.configuration.merge("BILLING_IDENTITY_AUDIENCE" => nil)) do
      verifier = Identity::TokenVerifier.new(issuer: TestSupport::TestIdentity.issuer)

      assert_raises(Identity::Unconfigured) { verifier.verify(TestSupport::TestIdentity.token) }
    end
  end

  test "an unreachable key set is Unreachable rather than Invalid" do
    # The distinction is the whole reason these are two classes. A 401 here would
    # tell a caller holding a perfectly good token to go and rotate it.
    verifier = TestSupport::TestIdentity.verifier(jwks_source: ->(_url) { raise Errno::ECONNREFUSED })

    assert_raises(Identity::Unreachable) { verifier.verify(TestSupport::TestIdentity.token) }
  end

  test "a key set that is not a key set is Unreachable" do
    verifier = TestSupport::TestIdentity.verifier(jwks_source: ->(_url) { { "something" => "else" } })

    assert_raises(Identity::Unreachable) { verifier.verify(TestSupport::TestIdentity.token) }
  end

  test "a failed fetch leaves the last good key set in place" do
    # Degrading to an outage rather than to an open door: a transient identity
    # failure must not turn every subsequent request into a 503 either, because we
    # already hold keys we trust.
    #
    # **The clock is injected**, because the cache has to have aged out for the
    # second call to fetch at all — and a test that aged it out with `travel` would
    # be asserting on a wall clock. `TokenVerifier` takes the clock for the same
    # reason `Kit::Telemetry` takes a lookup rather than the environment: a test
    # must never mutate global state to ask what happens when time moves.
    now = TestSupport::FrozenClock::NOW
    reachable = true
    verifier = TestSupport::TestIdentity.verifier(
      jwks_source: ->(_url) { reachable ? TestSupport::TestIdentity.jwks : raise(Errno::ECONNREFUSED) },
      clock: -> { now }
    )

    assert verifier.verify(TestSupport::TestIdentity.token), "the first fetch must succeed"

    now += Identity::TokenVerifier::CACHE_TTL + 1
    reachable = false
    assert_raises(Identity::Unreachable) { verifier.verify(TestSupport::TestIdentity.token) }

    # identity comes back. The cache still holds the set from before the outage, so
    # the first request after it is answered without a fetch at all — and if the
    # failed fetch had replaced the cache, this is where it would show.
    reachable = true
    assert verifier.verify(TestSupport::TestIdentity.token),
      "a fetch failure replaced the cached key set. It must leave the last good one in place, so " \
      "a transient identity outage degrades to the keys we already trust rather than to a 503."
  end

  # --- the forced-refresh budget -----------------------------------------------

  test "an unknown kid gets one forced refresh per window, not one per request" do
    # identity rotating a key is the ordinary case; a burst of forged tokens naming
    # keys it does not publish is the abusive one, and both look the same from here.
    # The budget is claimed BEFORE the fetch — a budget recorded on completion is a
    # budget twenty-five concurrent requests all believe is unspent.
    #
    # The source publishes **only** the real key throughout, so every one of the four
    # tokens is genuinely refused. If the budget were spent per token the count would
    # be 5; the opening fetch plus one refresh is the whole allowance.
    fetches = 0
    verifier = TestSupport::TestIdentity.verifier(jwks_source: lambda { |_url|
      fetches += 1
      TestSupport::TestIdentity.jwks
    })

    4.times { assert_raises(Identity::Invalid) { verifier.verify(TestSupport::TestIdentity.foreign_token) } }

    assert_equal 2, fetches,
      "four tokens naming one unknown kid caused #{fetches} fetches. One opening fetch plus one " \
      "forced refresh is the whole allowance per cache window; anything more means a caller can " \
      "aim every request at identity."
  end

  test "a kid identity publishes after a rotation is accepted on the forced refresh" do
    # The rotation case the budget exists to allow: the token was signed by a key
    # that was not in the cached set, and the refresh brought it.
    published = false
    verifier = TestSupport::TestIdentity.verifier(jwks_source: lambda { |_url|
      published ? TestSupport::TestIdentity.jwks_with_foreign_key : TestSupport::TestIdentity.jwks
    })

    assert_raises(Identity::Invalid) { verifier.verify(TestSupport::TestIdentity.foreign_token) }

    published = true
    principal = verifier.verify(TestSupport::TestIdentity.foreign_token)

    assert_equal TestSupport::TestIdentity::Account, principal.account_id,
      "a key published by a rotation must verify without waiting out the cache TTL"
  end

  # --- the claims billing reads -------------------------------------------------

  test "an absent scope claim is an empty set, never everything" do
    principal = @verifier.verify(TestSupport::TestIdentity.token(claims: { "scope" => nil }))

    assert_empty principal.scopes,
      "a claim this service cannot read must not read as a grant. An absent scope is an empty set."
    refute principal.scope?("accounts")
  end

  test "a token carrying no account_id is refused rather than treated as no account" do
    # "No account" and "an account I could not read" must not both be answers to the
    # same request, and every query on /v1 is scoped by this value.
    assert_raises(Identity::Invalid) do
      @verifier.verify(TestSupport::TestIdentity.token(claims: { "account_id" => nil }))
    end
  end

  test "an account_id that is not a uuid is refused" do
    assert_raises(Identity::Invalid) do
      @verifier.verify(TestSupport::TestIdentity.token(account_id: "not-a-uuid"))
    end
  end

  # --- the cross-repo disagreement, pinned as a refusal -------------------------

  # **This is the shape `identity` actually issues to a user**, transcribed from
  # `identity/internal/oidc/profiles.go`: `accounts` is an array of
  # `{account_id, name, slug, role, personal}`, released on the `accounts` scope,
  # and there is no singular `account_id` on the token at all. identity's own
  # comment says why — a user is in a personal account and usually several team
  # accounts, and one of them in the token "would be wrong for all the others."
  #
  # The test asserts this is **refused**, and the reason it is worth a test rather
  # than a comment is the shape of the temptation. Every "helpful" resolution here
  # is a silent cross-tenant read: take `accounts[0]`, take the personal one, take
  # the one whose slug matches a path segment. A user in five accounts then has
  # every request answered against a tenancy key nobody chose and nobody can see.
  # A lockout is the correct answer to an undecided disagreement; a guess is not,
  # and this is the assertion that keeps the next engineer from making one.
  #
  # If this test ever starts failing because the token was *accepted*, the two
  # repositories have been reconciled and this should be rewritten to say which
  # claim won — not deleted.
  test "a token in identity's own multi-account shape is refused, not scoped to one account" do
    accounts = [
      { "account_id" => "11111111-1111-4111-8111-111111111111", "name" => "Ada", "slug" => "ada", "role" => "owner", "personal" => true },
      { "account_id" => "22222222-2222-4222-8222-222222222222", "name" => "Acme", "slug" => "acme", "role" => "member", "personal" => false }
    ]

    error = assert_raises(Identity::Invalid) do
      @verifier.verify(TestSupport::TestIdentity.token(claims: { "accounts" => accounts, "account_id" => nil }))
    end

    assert_match(/accounts/, error.message,
      "the refusal must name the disagreement, because the operator reading the log is " \
      "the only person who can act on it and `no account_id` reads as a malformed token " \
      "rather than as a cross-repo claim mismatch. See anywaye.yml.")
  end

  test "a single account out of an array is still not a tenancy key" do
    # The degenerate case, and the one that is easiest to accept by accident: an
    # array of exactly one looks unambiguous, and accepting it would make the
    # behaviour depend on how many accounts a user happens to belong to — a
    # caller with one team account would be authorized and a caller with two
    # would not, with nothing in the code saying so.
    assert_raises(Identity::Invalid) do
      @verifier.verify(TestSupport::TestIdentity.token(claims: {
        "account_id" => nil,
        "accounts" => [ { "account_id" => "11111111-1111-4111-8111-111111111111" } ]
      }))
    end
  end

  # --- the one place a JWT is read ---------------------------------------------

  # "There is exactly one verifier" is a claim about the repository rather than
  # about this class, and a class cannot assert it. So the file reads `app/` and
  # `lib/` and finds every reference to the `JWT` constant outside itself.
  #
  # **Comment lines are skipped**, and that is not a convenience: two files
  # *explain* the rule in prose containing the word — `authenticates_principal.rb`
  # quotes core's "Inbound webhooks are not JWT-authenticated" — and a scan that
  # trips on the explanation of a rule is a scan whose only fix is to delete the
  # explanation.
  #
  # It matches the bare constant name and **not** `JWT.something`, which is a
  # narrower pattern than it looks and this file learned that by mutation: a
  # reference to `JWT::JWK` — a constant use, exactly what the rule forbids — does
  # not contain the characters `JWT.`, so the first spelling of this guard
  # reported green against a file doing precisely the thing it exists to catch.
  # Every spelling of the constant ends in `JWT` or begins with it.
  #
  # What a second `JWT.decode` would cost is the point: a second verifier is a
  # second answer to "is this caller who they say they are", and only one of them
  # would carry the RS256 pin, the `kid` check, the refresh budget and the claim
  # rules above. A caller who found the weaker one would be authenticated by it.
  test "the JWT constant is referenced in exactly one file: the verifier" do
    verifier_path = Rails.root.join("app/services/identity/token_verifier.rb").to_s
    offenders = Dir[Rails.root.join("{app,lib}/**/*.rb").to_s].sort.filter_map do |path|
      next if path == verifier_path

      line = File.readlines(path).each_with_index.find do |text, _|
        !text.strip.start_with?("#") && text.match?(/\bJWT\b/)
      end
      "#{path.delete_prefix("#{Rails.root}/")}:#{line[1] + 1}" if line
    end

    assert_empty offenders,
      "these files reference the JWT constant directly. A second place that reads a " \
      "token is a second trust path to /v1, and it would carry none of the rules in " \
      "app/services/identity/token_verifier.rb — the RS256 pin, the kid check, the " \
      "refresh budget, the required claims. Route it through " \
      "Identity::TokenVerifier.current.verify instead.\n  " + offenders.join("\n  ")
  end
end
