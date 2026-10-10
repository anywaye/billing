# frozen_string_literal: true

require "json"
require "base64"
require "time"
require "jwt"
require "cafaye/principal"
require "cafaye/token"
require "cafaye/jwks/cache"
require "cafaye/jwks/fetcher"
require "cafaye/jwks/transport"

module Cafaye
  # Verifies a cafaye access token against identity's published JWKS.
  #
  # The order of the checks is the design, and it is `guard`'s order, because
  # `guard` is the only implementation in the fleet and this has to match it:
  #
  #   1. **The protected header**, before anything is fetched. `alg` and `kid`
  #      are attacker-controlled, so an `alg: none` or HS256 token must not be
  #      able to make this process call identity, and a malformed token must
  #      cost no network. A test per case asserts the fetch count is zero.
  #   2. **The key set**, from a cache that is bounded three ways. An unknown
  #      `kid` buys one forced refresh per interval, never one per request.
  #   3. **The signature**, against the key the `kid` named.
  #   4. **The claims.**
  #
  # The distinction the whole file is built around: **a token that is not
  # acceptable raises `TokenInvalid`; a key set that could not be fetched raises
  # `JwksUnavailable`.** A caller maps the first to 401 and the second to 503,
  # because identity being unreachable is not the caller's credential failing
  # and a 401 sends an operator to rotate a token that was fine.
  #
  # Configuration is validated in the constructor, so a typo in an environment
  # variable is a boot failure rather than a 503 on every request.
  class TokenVerifier
    # RS256 and nothing else.
    #
    # The algorithm is a property of the key set identity publishes, not a hint
    # the token carries, so it is pinned here and checked before anything is
    # fetched. core's `docs/openapi-conventions.md` allows RS256 and ES256;
    # `guard` allows RS256 only; this matches `guard`, because accepting an
    # algorithm no key set uses buys nothing and widens what a token can ask
    # for. Widening is one line, and it should happen when identity publishes
    # ES256 keys. The decision is recorded in `cafaye.yml`.
    ALGORITHMS = [ "RS256" ].freeze

    # Where identity publishes its keys. Fixed, and appended to the issuer.
    JWKS_PATH = "/.well-known/jwks.json"

    # Both scope claim names are read, and their contents unioned.
    #
    # core's conventions say `scopes`, an array, required. `guard` reads
    # `scope`, a space-separated string, optional, and records the conflict as
    # its own open decision. `identity` mints no tokens yet, so there is no
    # implementation to read the names off. Reading both is the defensive
    # answer and the restrictive one at the same time: a verifier that read one
    # name while the issuer sent the other produces an empty scope set, which is
    # a safe failure for a gate and a silent one for anything that reads the
    # scopes to decide what to render.
    DEFAULT_SCOPE_CLAIMS = %w[scopes scope].freeze

    # core's name for the tenancy claim. Not required by default, and the reason
    # is in `cafaye.yml`: a library that refused every token without
    # `account_id` would refuse every token `guard` can currently mint, which
    # makes this migration a big-bang cutover rather than a gem.
    DEFAULT_ACCOUNT_CLAIM = "account_id"

    # The claims core's `docs/openapi-conventions.md` lists as required:
    # `iss`, `aud`, `sub`, `exp`, `iat`, `jti`.
    DEFAULT_REQUIRED_CLAIMS = %w[iss aud sub exp iat jti].freeze

    DEFAULT_CACHE_TTL = 300
    DEFAULT_TIMEOUT = 5
    DEFAULT_UNKNOWN_KID_TTL = 30
    DEFAULT_MIN_REFRESH_INTERVAL = 30

    # Zero by default, and that is a decision rather than an omission. A token
    # one second in the future is refused, which is correct and will surface as
    # a fleet of 401s on a deployment whose clocks have drifted. A deployment
    # that cannot keep clocks in step says so with `leeway:`, which is one
    # constructor argument. See `cafaye.yml`.
    DEFAULT_LEEWAY = 0

    # Hosts allowed to serve the key set over plain http. A developer's compose
    # stack, and nothing else.
    LOOPBACK_HOSTS = [ "127.0.0.1", "::1", "localhost" ].freeze

    attr_reader :issuer, :audience, :jwks_url, :jwks_cache_ttl, :jwks_timeout,
                :unknown_kid_ttl, :min_refresh_interval, :leeway,
                :account_claim, :scope_claims, :required_claims

    # @param issuer [String] an origin such as `https://identity.cafaye.com`.
    #   It is both the expected `iss` and the base the JWKS path is appended to.
    # @param audience [String] the `client_id` every token must be addressed to.
    # @param jwks_url [String, nil] a key set served somewhere other than the
    #   issuer's own well-known path.
    # @param clock [#call] returns a `Time`. Injected, and see `#verify_time_claims`
    #   for why the time-based claims are checked here rather than by the gem.
    def initialize(issuer:, audience:, jwks_url: nil, jwks_cache_ttl: DEFAULT_CACHE_TTL,
                   jwks_timeout: DEFAULT_TIMEOUT, unknown_kid_ttl: DEFAULT_UNKNOWN_KID_TTL,
                   min_refresh_interval: DEFAULT_MIN_REFRESH_INTERVAL, leeway: DEFAULT_LEEWAY,
                   account_claim: DEFAULT_ACCOUNT_CLAIM, scope_claims: DEFAULT_SCOPE_CLAIMS,
                   required_claims: DEFAULT_REQUIRED_CLAIMS, require_account: false,
                   clock: -> { Time.now }, logger: nil, transport: nil, fetcher: nil)
      @issuer = parse_issuer(issuer)
      @audience = parse_text(audience, "audience")
      @jwks_url = parse_jwks_url(jwks_url) || "#{@issuer}#{JWKS_PATH}"
      @jwks_cache_ttl = positive_integer(jwks_cache_ttl, "jwks_cache_ttl")
      @jwks_timeout = positive_integer(jwks_timeout, "jwks_timeout")
      @unknown_kid_ttl = positive_integer(unknown_kid_ttl, "unknown_kid_ttl")
      @min_refresh_interval = positive_integer(min_refresh_interval, "min_refresh_interval")
      @leeway = non_negative_integer(leeway, "leeway")
      @account_claim = parse_claim_name(account_claim, "account_claim")
      @scope_claims = parse_claim_list(scope_claims, "scope_claims")
      @required_claims = parse_claim_list(required_claims, "required_claims")
      @require_account = require_account
      @logger = logger
      @clock = clock
      @cache = build_cache(fetcher || default_fetcher, clock)
    end

    def configured?
      true
    end

    # The verified caller, or nil.
    #
    # For "is there a token here, and is it any good". Anything that needs the
    # reason calls `verify!`, because a nil that cannot say why is a nil an
    # operator debugs with a breakpoint. This is the door that logs: the caller
    # has told us it wanted an answer rather than an exception, so the refusal
    # is recorded in the library's own vocabulary.
    def verify(token)
      verify!(token)
    rescue Errors::TokenInvalid, Errors::JwksUnavailable => error
      log_refusal(error)
      nil
    end

    # The verified caller, or a refusal.
    #
    # Silent on refusal, deliberately. The caller holds the exception and is
    # about to log a 401 of its own; a library that also logged would put the
    # same refusal in two places with two levels and no way to tell which one a
    # deployment had turned up.
    #
    # @return [Cafaye::Principal]
    # @raise [Cafaye::Errors::TokenInvalid] the token is not acceptable
    # @raise [Cafaye::Errors::JwksUnavailable] the keys could not be fetched
    def verify!(raw_token)
      token = wrap(raw_token)
      kid = kid_from_header(token)

      key = @cache.verification_key_for(kid)
      raise Errors::UnknownKey, "token was signed by an unknown key" if key.nil?

      principal_from(decode(token, kid, key))
    end

    private

    def wrap(raw_token)
      return raw_token if raw_token.is_a?(Token)
      return Token.new(raw_token) if raw_token.is_a?(String)

      raise Errors::TokenInvalid, "no token was presented"
    end

    # The protected header, read before anything is fetched and before any claim
    # is looked at. This runs first so an `alg: none` or HS256 token costs no
    # network and never reaches a verifier, and so a malformed token costs no
    # network either.
    def kid_from_header(token)
      raise Errors::TokenInvalid, "token is malformed" if token.empty?

      header = decode_unverified(token)
      unless ALGORITHMS.include?(header["alg"])
        # The offending algorithm is not named. It came from the token, and
        # naming it back puts attacker-chosen text into a message that gets
        # logged; "not accepted" says everything an operator needs.
        raise Errors::AlgorithmNotAllowed, "token algorithm is not accepted"
      end

      kid = header["kid"]
      raise Errors::UnknownKey, "token header names no key" unless kid.is_a?(String) && !kid.empty?

      kid
    end

    def decode_unverified(token)
      parsed = JSON.parse(base64url_decode(token.reveal.split(".").first.to_s))
      raise Errors::TokenInvalid, "token is malformed" unless parsed.is_a?(Hash)

      parsed
    rescue ArgumentError, JSON::ParserError
      raise Errors::TokenInvalid, "token is malformed"
    end

    def base64url_decode(segment)
      Base64.urlsafe_decode64(segment + ("=" * ((4 - (segment.length % 4)) % 4)))
    end

    # The gem is told to check the signature, the issuer, the audience, the
    # token id and the presence of the required claims, and is told **not** to
    # check `exp`, `nbf` or `iat`.
    #
    # `jwt`'s own claim verifiers call `Time.now` directly and take no clock.
    # That makes a library which promises an injectable clock a library whose
    # clock is only injectable for the cache, and it makes every time-based
    # assertion in this suite a race against the wall clock. So those three are
    # checked here, against the injected clock, and the gem is switched off for
    # them. The cost is three comparisons; the benefit is that the injected
    # clock is the only clock in the process, which is what lets the suite be
    # deterministic on any day and lets a host application test a rotated clock.
    def decode(token, kid, key)
      payload, header = JWT.decode(token.reveal, key, true, **decode_options)

      # Defence in depth. The gem was given exactly one key, and that key is the
      # one this `kid` resolved to, so the header's `kid` cannot name another
      # key. Asserting it anyway means a future change to how the key is
      # selected cannot quietly become "verified against whichever key was
      # convenient".
      raise Errors::UnknownKey, "token header names another key" unless header["kid"] == kid

      [ payload, header ]
    rescue JWT::ExpiredSignature
      raise Errors::ClaimInvalid, "exp"
    rescue JWT::ImmatureSignature
      raise Errors::ClaimInvalid, "nbf"
    rescue JWT::InvalidIssuerError
      raise Errors::ClaimInvalid, "iss"
    rescue JWT::InvalidAudError
      raise Errors::ClaimInvalid, "aud"
    rescue JWT::InvalidIatError
      raise Errors::ClaimInvalid, "iat"
    rescue JWT::InvalidJtiError
      raise Errors::ClaimInvalid, "jti"
    rescue JWT::MissingRequiredClaim => error
      # The gem's message is "Missing required claim <name>". Only the name is
      # kept, and it goes through `ClaimInvalid`'s own sanitiser, so a claim
      # name that somehow contained punctuation is not interpolated verbatim.
      raise Errors::ClaimInvalid, error.message.to_s[/required claim ([a-z][a-z0-9_]*)/, 1] || "unknown"
    rescue JWT::IncorrectAlgorithm, JWT::SignatureError
      # Covers a signature that does not verify and a header the gem considers
      # unusable. Its messages quote the values that failed, and a value that
      # failed verification is exactly the thing not to write down.
      raise Errors::SignatureInvalid, "token signature does not verify"
    rescue JWT::DecodeError
      # Deliberately broad, and deliberately last. `jwt` folds several unrelated
      # failures into `JWT::DecodeError` — a payload that is not JSON, a
      # segment that is not base64url, too few segments — and its messages quote
      # the offending text. A claim-shape failure below catches the payload case
      # with a claim name; everything else is "not a token".
      raise Errors::TokenInvalid, "token is malformed"
    end

    def decode_options
      {
        algorithms: ALGORITHMS,
        verify_expiration: false,
        verify_not_before: false,
        verify_iat: false,
        verify_iss: true,
        iss: issuer,
        verify_aud: true,
        aud: audience,
        verify_jti: true,
        required_claims: required_claims
      }
    end

    # `exp`, `nbf` and `iat`, against the injected clock.
    #
    # Every value is required to be a number. A string `exp` is not a date the
    # library will try to interpret — `"exp" => "never"` is a claim this
    # library refuses rather than one it guesses about, and `to_i` on a string
    # that is not a number is `0`, which is an expiry in 1970 and would be
    # accepted by anything that coerced.
    def verify_time_claims(payload)
      raise Errors::ClaimInvalid, "exp" if numeric_claim(payload, "exp") <= (@clock.call.to_i - leeway)

      if payload.key?("nbf")
        raise Errors::ClaimInvalid, "nbf" if numeric_claim(payload, "nbf") > (@clock.call.to_i + leeway)
      end

      return unless numeric_claim(payload, "iat") > (@clock.call.to_i + leeway)

      raise Errors::ClaimInvalid, "iat"
    end

    def numeric_claim(payload, claim)
      value = payload[claim]
      raise Errors::ClaimInvalid, claim unless value.is_a?(Numeric)

      value.to_i
    end

    def principal_from(decoded)
      payload = decoded.first
      verify_time_claims(payload)

      Principal.new(
        subject: required_string(payload, "sub"),
        account_id: account_id_of(payload),
        scopes: scopes_of(payload),
        expires_at: Time.at(numeric_claim(payload, "exp")).utc,
        issued_at: Time.at(numeric_claim(payload, "iat")).utc,
        issuer: payload.fetch("iss"),
        audience: audience_of(payload),
        token_id: required_string(payload, "jti")
      )
    end

    def required_string(payload, claim)
      value = payload[claim]
      raise Errors::ClaimInvalid, claim unless value.is_a?(String) && !value.empty?

      value
    end

    # `aud` may be a string or an array of strings (RFC 7519 4.1.3), and an
    # issuer that sends an array is not wrong. What is reported is the audience
    # *this* service matched on, not the whole array: a principal carrying every
    # audience the token names is a principal carrying another service's
    # identifier into this service's logs.
    def audience_of(payload)
      value = payload.fetch("aud")
      return value if value.is_a?(String)

      value.find { |entry| entry == audience }
    end

    # The tenant. `nil` when the claim is absent and the service did not require
    # it, and never an empty string: a service that forgets to check for `nil`
    # should get `nil` and a `NoMethodError` on `nil.account_id`, not an empty
    # string and a query scoped to nothing that returns every row.
    def account_id_of(payload)
      value = payload[account_claim]
      raise Errors::ClaimInvalid, account_claim if @require_account && value.to_s.empty?

      case value
      when nil then nil
      when String then value.empty? ? nil : value
      when Integer then value.to_s
      else raise Errors::ClaimInvalid, account_claim
      end
    end

    # The scopes, from every configured claim name, unioned.
    #
    # A claim that is present and of a shape this library cannot read is a
    # refusal, not an empty set. An empty set is a safe failure for a gate; a
    # claim the issuer meant and this library could not read is either a bug on
    # one side or an attack on the other, and both deserve a refusal rather than
    # a quiet empty.
    def scopes_of(payload)
      scope_claims.flat_map { |claim| scopes_in(payload, claim) }.sort.uniq
    end

    def scopes_in(payload, claim)
      value = payload[claim]
      case value
      when nil then []
      when String then value.split(/\s+/).reject(&:empty?)
      when Array then array_of_scopes(value, claim)
      else raise Errors::ClaimInvalid, claim
      end
    end

    def array_of_scopes(value, claim)
      value.each do |entry|
        raise Errors::ClaimInvalid, claim unless entry.is_a?(String) && !entry.empty?
      end
      value
    end

    # --- construction helpers ----------------------------------------------

    def build_cache(fetcher, clock)
      Jwks::Cache.new(
        fetcher: fetcher,
        clock: clock,
        ttl: jwks_cache_ttl,
        unknown_kid_ttl: unknown_kid_ttl,
        min_refresh_interval: min_refresh_interval
      )
    end

    def default_fetcher
      Jwks::Fetcher.new(transport: Jwks::Transport.new(timeout: jwks_timeout), url: jwks_url, clock: @clock)
    end

    def parse_issuer(value)
      uri = parse_http_uri(parse_text(value, "issuer"), "issuer")

      # No path: the fixed JWKS path is appended to this, so a base with a path
      # of its own would put the key set somewhere nobody serves it from. The
      # trailing slash is dropped because it is what an operator types out of
      # habit and keeping it would join into `https://host//.well-known/…`.
      unless uri.path.empty? || uri.path == "/"
        raise Errors::ConfigurationError, "issuer must be a base url with no path"
      end

      origin(uri)
    end

    def parse_jwks_url(value)
      return nil if value.nil?

      uri = parse_http_uri(parse_text(value, "jwks_url"), "jwks_url")
      unless uri.query.nil? && uri.fragment.nil?
        # A query string on the key-set URL is a place for a credential to end
        # up, and this library writes that URL into a log line when a fetch
        # fails. Refusing it here is cheaper than redacting it there.
        raise Errors::ConfigurationError, "jwks_url must not carry a query or fragment"
      end

      uri.to_s
    end

    def parse_http_uri(value, field)
      uri = begin
        URI.parse(value)
      rescue URI::InvalidURIError
        raise Errors::ConfigurationError, "#{field} must be an absolute http(s) url"
      end

      unless %w[http https].include?(uri.scheme) && uri.host
        raise Errors::ConfigurationError, "#{field} must be an absolute http(s) url"
      end

      # Plain http is allowed only to loopback, which is a developer's compose
      # stack. `guard` accepts `http:` for any host, which means a
      # misconfigured issuer silently downgrades key distribution to plaintext.
      if uri.scheme == "http" && !LOOPBACK_HOSTS.include?(uri.host)
        raise Errors::ConfigurationError, "#{field} must be https, or http on loopback"
      end

      uri
    end

    def origin(uri)
      port = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ""
      "#{uri.scheme}://#{uri.host}#{port}"
    end

    def parse_text(value, field)
      text = value.is_a?(String) ? value.strip : ""
      raise Errors::ConfigurationError, "#{field} must be a non-empty string" if text.empty?

      text
    end

    def positive_integer(value, field)
      raise Errors::ConfigurationError, "#{field} must be an integer >= 1" unless value.is_a?(Integer) && value >= 1

      value
    end

    def non_negative_integer(value, field)
      unless value.is_a?(Integer) && value >= 0
        raise Errors::ConfigurationError, "#{field} must be an integer >= 0"
      end

      value
    end

    # A claim name is a fixed word from a closed vocabulary, and it is about to
    # go into exception messages. Checked here so a configuration typo is a
    # startup error rather than a message that says `token claim 'Sub ' is not
    # valid` for the life of the deployment.
    def parse_claim_name(value, field)
      text = parse_text(value, field)
      raise Errors::ConfigurationError, "#{field} must be a lower-case claim name" unless /\A[a-z][a-z0-9_]*\z/.match?(text)

      text
    end

    def parse_claim_list(value, field)
      list = Array(value)
      if list.empty? || list.any? { |entry| !entry.is_a?(String) || entry.strip.empty? }
        raise Errors::ConfigurationError, "#{field} must be a non-empty list of claim names"
      end

      list.map { |entry| parse_claim_name(entry, field) }.uniq
    end

    # --- logging ------------------------------------------------------------

    # A refusal, at the level an operator wants, in the library's own
    # vocabulary.
    #
    # **The reason and nothing else.** Not the token, not a claim value, not a
    # key id, not the expected issuer. A log line is the most-read artefact a
    # service produces and the one with the longest life, and a line reading
    # `refused a token: token claim 'aud' is not valid` tells an operator
    # everything they need, while one reading `token from usr_01J9… presented by
    # 10.0.0.4` tells them nothing they were allowed to see.
    def log_refusal(error)
      return if @logger.nil?

      @logger.warn("refused a token: #{error.message}")
    end
  end
end
