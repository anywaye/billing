module Identity
  # The one place a caller's identity is established, and the only place a JWT is
  # read in this repository.
  #
  # ## What this is
  #
  # A verifier, not a seam. courier's `CourierWeb.Plugs.Principal` resolves a
  # caller through a configurable resolver whose default authenticates nobody,
  # because identity's JWKS machinery had not landed when it was written. That
  # decision was right for courier and it is **not** right here: billing holds
  # prices, payment records and the ability to cancel somebody's subscription, and
  # a default that authenticates nobody is a locked door — correct, but a locked
  # door nobody can open. So this service ships the real verifier, and the failure
  # direction is the one the brief asks for: **an unconfigured or unreachable
  # identity locks `/v1`, and never serves it.**
  #
  # Concretely, in the order a request meets it:
  #
  #   1. **No issuer or no audience configured** -> `Identity::Unconfigured` -> 503.
  #      A deployment that has not told this service how to verify a token has not
  #      earned the right to serve `/v1`, and the operator's first question is
  #      "what did I forget to set", which a 401 sends them away from.
  #   2. **The protected header is read before anything else.** `alg` must be
  #      RS256 and `kid` must be a non-empty string, both checked on the *token*.
  #      This runs before any network call, so a forged `alg: none` or an HS256
  #      token signed with a published public key costs identity nothing and never
  #      aims traffic at it. The algorithm is a property of the key set identity
  #      publishes, not a hint a caller supplies.
  #   3. **The key set is fetched once and cached by `kid`**, with a bounded TTL.
  #      An unknown `kid` gets **one** forced refresh per cache window: identity
  #      rotating a key is the ordinary case, and a burst of forged tokens naming
  #      keys it does not publish is the abusive one. The budget is claimed before
  #      the fetch and is spent whether the fetch succeeds or not, because a
  #      refresh that fails is precisely the situation in which an unlimited fetch
  #      allowance aimed at identity is worth having.
  #   4. **The signature, then the claims.** `iss`, `aud`, `exp` and the presence
  #      of `sub`, `iat`, `jti` and `account_id` are all required. `account_id` is
  #      what every query on `/v1` is scoped by, and a token without one cannot be
  #      scoped — see `Principal`.
  #
  # ## Why `jwt` and not OpenSSL
  #
  # Same reasoning as the `stripe` gem: this is the one place a forged amount must
  # never be believed, and a hand-rolled verifier is how `alg: none` and
  # HS256-signed-with-the-public-key get through. The gem does the signature; this
  # class does the platform's rules about *which* signatures, and nothing about
  # what the claims mean.
  #
  # ## Why the answer is not "it depends"
  #
  # Every refusal here is one of the three classes in `Identity`, and the class is
  # the whole of what a caller learns. Which of the four things was wrong with a
  # token — its signature, its expiry, its issuer, its audience — is not something
  # a caller learns by trying, so the 401 body is one fixed sentence and the
  # specific reason goes to the log with the trace id.
  class TokenVerifier
    ALGORITHM = "RS256"

    JWKS_PATH = "/.well-known/jwks.json"

    CACHE_TTL = 5.minutes

    FETCH_TIMEOUT = 5.seconds

    REQUIRED_CLAIMS = %w[iss aud sub exp iat jti].freeze

    # The class-level handle, so a deployment configures one verifier and a spec
    # swaps it. Read from the environment at construction rather than memoized at
    # boot, so a rotated issuer is picked up without a redeploy — the same reason
    # `Processor::StripeClient` does it.
    class << self
      def current
        @current ||= new
      end

      attr_writer :current
    end

    attr_reader :issuer, :audience, :jwks_url

    # `jwks_source` is the seam the specs use, and it is a **callable returning the
    # key set**, not a stubbed verifier: the signature is checked for real against
    # the keys it returns, so a test cannot pass by arranging a principal. Production
    # leaves it nil and the fetch goes to identity over HTTPS.
    def initialize(issuer: nil, audience: nil, jwks_url: nil, jwks_source: nil, clock: -> { Time.current })
      @issuer = (issuer || ENV["BILLING_IDENTITY_ISSUER"]).presence
      @audience = (audience || ENV["BILLING_IDENTITY_AUDIENCE"]).presence
      @clock = clock
      @jwks_source = jwks_source
      @jwks_url = jwks_url.presence || default_jwks_url
      @keys = nil
      @fetched_at = nil
      @window = 0
      @refresh_spent_in = nil
    end

    # The verified caller, or one of the three refusals.
    #
    # `token` is the credential as it arrived, unparsed. Nothing here logs it,
    # and nothing here puts it in an exception message: a bearer token in a log
    # line is a bearer token in a searchable store.
    def verify(token)
      require_configured!
      header = protected_header(token)
      key = key_for(header.fetch("kid"), fetched: @keys.nil? || stale?)
      payload = verify_signature(token, header, key)

      Principal.build(payload, issuer: issuer)
    end

    private
      # Both halves, or the service does not know how to verify anything and says
      # so rather than accepting what it was given.
      def require_configured!
        raise Unconfigured, "no issuer configured" if issuer.blank?
        raise Unconfigured, "no audience configured" if audience.blank?
      end

      def default_jwks_url
        return nil if issuer.blank?

        "#{issuer.chomp("/")}#{JWKS_PATH}"
      end

      # The header, read from the token and **not** from anything identity said.
      #
      # `alg` is checked against a constant before the key set is touched, and
      # `kid` must be a non-empty string. This is the cheapest and the sharpest
      # refusal in the whole verifier: an `alg: none` token and an HS256 token
      # signed with the published public key both die here, without a network
      # call, and a token that is not three base64url segments at all dies before
      # it can be turned into a JSON parse error we would have to classify.
      def protected_header(token)
        segments = token.to_s.split(".")
        raise Invalid, "malformed token" unless segments.size == 3

        header = decode_json(segments.first)
        raise Invalid, "malformed token header" unless header.is_a?(Hash)

        unless header["alg"] == ALGORITHM
          raise Invalid, "algorithm #{header['alg'].inspect} is not accepted"
        end
        raise Invalid, "token header names no key" unless header["kid"].is_a?(String) && !header["kid"].empty?

        header
      rescue ArgumentError, JSON::ParserError
        raise Invalid, "malformed token header"
      end

      # The key for one `kid`, fetching the set if this is the first request or
      # the cache has aged out.
      #
      # An unknown `kid` is the rotation case and the forgery case at once, so it
      # gets exactly one forced refresh per cache window. Claimed **before** the
      # fetch: a budget recorded on completion is a budget twenty-five concurrent
      # requests all believe is still unspent.
      def key_for(kid, fetched:)
        set = keys
        found = set.find { |key| key[:kid] == kid }

        if found.nil? && !fetched && refresh_available?
          spend_refresh!
          set = keys(force: true)
          found = set.find { |key| key[:kid] == kid }
        end

        raise Invalid, "token was signed by an unknown key" if found.nil?

        found.fetch(:key)
      end

      def refresh_available?
        open_window!
        @refresh_spent_in != @window
      end

      def spend_refresh!
        @refresh_spent_in = @window
      end

      # A window number rather than a boolean, because a flag cannot tell this
      # cache window from the last one — which is either why it was never cleared
      # or why clearing it let a burst back in over again.
      def open_window!
        @window += 1 if @keys.nil? || stale?
        @refresh_spent_in = nil if @keys.nil? || stale?
      end

      def stale?
        @fetched_at.nil? || @clock.call - @fetched_at >= CACHE_TTL
      end

      # The key set, as `[kid, public_key]` pairs.
      #
      # Stored **only on success**: a failed fetch must leave the last good set in
      # place rather than replacing it with an outage, so a transient identity
      # failure degrades to the keys we already trust rather than to an open door
      # or a permanent lock.
      def keys(force: false)
        if !force && !stale?
          return @keys
        end

        @keys = load_keys
        @fetched_at = @clock.call
        @keys
      end

      def load_keys
        document = @jwks_source ? @jwks_source.call(jwks_url) : fetch_jwks
        entries = document.is_a?(Hash) ? document["keys"] : nil
        raise Unreachable, "key set at #{jwks_url} is not a key set" unless entries.is_a?(Array)

        entries.filter_map { |entry| import_key(entry) }
      rescue Unreachable
        raise
      rescue StandardError => e
        raise Unreachable, "could not read the key set at #{jwks_url}: #{e.class}"
      end

      # One usable entry, or nil.
      #
      # `alg` is checked **when present and refused when it disagrees**, rather than
      # required. RFC 7517 makes `alg` optional on a published key and identity does
      # send it (`internal/oidc/keys.go`), but a set that omits it is still a set of
      # keys, and requiring it would lock `/v1` against a conforming peer. What is
      # not optional is that the key is RSA: the accepted algorithm is pinned to
      # RS256, and an `oct` entry is a symmetric key, which is the one thing an
      # RS256 verifier must never be handed.
      #
      # The class is checked after import rather than the `kty` before it, because
      # `JWT::JWK.import` is what actually parses the material and a `kty` of `RSA`
      # over an octet string is a question only the importer can answer.
      def import_key(entry)
        return nil unless entry.is_a?(Hash) && entry["kid"].is_a?(String) && !entry["kid"].empty?
        return nil if entry.key?("alg") && entry["alg"] != ALGORITHM

        key = JWT::JWK.import(entry).public_key
        key.is_a?(OpenSSL::PKey::RSA) ? { kid: entry["kid"], key: key } : nil
      rescue StandardError
        nil
      end

      def fetch_jwks
        uri = URI.parse(jwks_url.to_s)
        raise Unconfigured, "no issuer configured" if jwks_url.blank?

        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
          open_timeout: FETCH_TIMEOUT, read_timeout: FETCH_TIMEOUT) do |http|
          response = http.get(uri.request_uri, { "Accept" => "application/json" })
          raise Unreachable, "key set at #{jwks_url} answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body)
        end
      rescue JSON::ParserError => e
        raise Unreachable, "key set at #{jwks_url} is not JSON: #{e.class}"
      rescue SystemCallError, IOError, Timeout::Error, SocketError, URI::InvalidURIError => e
        raise Unreachable, "key set at #{jwks_url} is unreachable: #{e.class}"
      end

      def verify_signature(token, header, key)
        payload, = JWT.decode(token, key, true,
          algorithms: [ ALGORITHM ],
          verify_expiration: true,
          verify_not_before: true,
          verify_iat: true,
          iss: issuer,
          verify_iss: true,
          aud: audience,
          verify_aud: true,
          required_claims: REQUIRED_CLAIMS)

        payload
      rescue JWT::DecodeError => e
        raise Invalid, "token refused: #{e.class}"
      end

      # One JSON segment, read as bytes.
      #
      # `urlsafe_decode64` takes the unpadded form and does not take a `padding:`
      # keyword on this Ruby — which is worth knowing, because the unpadded form is
      # what a JWT carries and the obvious spelling of this line raises
      # `ArgumentError` rather than decoding. A segment that is not base64 at all
      # raises `ArgumentError` from the same place, which is why the rescue below
      # covers both: "not a JWT" and "not JSON" are one refusal.
      def decode_json(segment)
        JSON.parse(Base64.urlsafe_decode64(segment))
      end
  end
end
