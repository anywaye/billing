require "test_helper"

class IdentityTokenVerifierTest < ActiveSupport::TestCase
  setup do
    @verifier = TestSupport::TestIdentity.verifier
  end


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
    with_env(TestSupport::TestIdentity.configuration.merge("BILLING_IDENTITY_AUDIENCE" => nil)) do
      verifier = Identity::TokenVerifier.new(issuer: TestSupport::TestIdentity.issuer)

      assert_raises(Identity::Unconfigured) { verifier.verify(TestSupport::TestIdentity.token) }
    end
  end

  test "an unreachable key set is Unreachable rather than Invalid" do
    verifier = TestSupport::TestIdentity.verifier(jwks_source: ->(_url) { raise Errno::ECONNREFUSED })

    assert_raises(Identity::Unreachable) { verifier.verify(TestSupport::TestIdentity.token) }
  end

  test "a key set that is not a key set is Unreachable" do
    verifier = TestSupport::TestIdentity.verifier(jwks_source: ->(_url) { { "something" => "else" } })

    assert_raises(Identity::Unreachable) { verifier.verify(TestSupport::TestIdentity.token) }
  end

  test "a failed fetch leaves the last good key set in place" do
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

    reachable = true
    assert verifier.verify(TestSupport::TestIdentity.token),
      "a fetch failure replaced the cached key set. It must leave the last good one in place, so " \
      "a transient identity outage degrades to the keys we already trust rather than to a 503."
  end


  test "an unknown kid gets one forced refresh per window, not one per request" do
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


  test "an absent scope claim is an empty set, never everything" do
    principal = @verifier.verify(TestSupport::TestIdentity.token(claims: { "scope" => nil }))

    assert_empty principal.scopes,
      "a claim this service cannot read must not read as a grant. An absent scope is an empty set."
    refute principal.scope?("accounts")
  end

  test "a token carrying no account_id is refused rather than treated as no account" do
    assert_raises(Identity::Invalid) do
      @verifier.verify(TestSupport::TestIdentity.token(claims: { "account_id" => nil }))
    end
  end

  test "an account_id that is not a uuid is refused" do
    assert_raises(Identity::Invalid) do
      @verifier.verify(TestSupport::TestIdentity.token(account_id: "not-a-uuid"))
    end
  end


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
    assert_raises(Identity::Invalid) do
      @verifier.verify(TestSupport::TestIdentity.token(claims: {
        "account_id" => nil,
        "accounts" => [ { "account_id" => "11111111-1111-4111-8111-111111111111" } ]
      }))
    end
  end


  test "the JWT constant is referenced in exactly one file: the verifier" do
    verifier_path = Rails.root.join("app/services/identity/token_verifier.rb").to_s
    offenders = Dir[Rails.root.join("{app,lib}/**/*.rb").to_s].sort.filter_map do |path|
      next if path == verifier_path

      line = File.readlines(path).each_with_index.find do |text, _|
        !text.strip.start_with?("#") && text.match?(/\bJWT\b/)
      end
    end

    assert_empty offenders,
      "these files reference the JWT constant directly. A second place that reads a " \
      "token is a second trust path to /v1, and it would carry none of the rules in " \
      "app/services/identity/token_verifier.rb — the RS256 pin, the kid check, the " \
      "refresh budget, the required claims. Route it through " \
      "Identity::TokenVerifier.current.verify instead.\n  " + offenders.join("\n  ")
  end
end
