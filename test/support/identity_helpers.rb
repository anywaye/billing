module TestSupport
  module TestIdentity
    AUDIENCE = "billing".freeze
    KID = "test-key-1".freeze

    FOREIGN_KID = "test-key-not-published".freeze

    class << self
      def issuer = "https://identity.test"

      def private_key
        @private_key ||= OpenSSL::PKey::RSA.generate(2048)
      end

      def foreign_key
        @foreign_key ||= OpenSSL::PKey::RSA.generate(2048)
      end

      def jwks
        @jwks ||= exported([ JWT::JWK.new(private_key.public_key, kid: KID) ])
      end

      def jwks_with_foreign_key
        @jwks_with_foreign_key ||= exported([
          JWT::JWK.new(private_key.public_key, kid: KID),
          JWT::JWK.new(foreign_key.public_key, kid: FOREIGN_KID)
        ])
      end

      def exported(keys)
        JSON.parse(JWT::JWK::Set.new(keys).export.to_json)
      end

      def verifier(jwks_source: nil, **overrides)
        source = jwks_source || ->(_url) { jwks }
        Identity::TokenVerifier.new(
          issuer: issuer,
          audience: AUDIENCE,
          jwks_source: source,
          **overrides
        )
      end

      def token(account_id: Account, subject: "user-#{Account}", scopes: %w[openid accounts],
                expires_at: nil, issued_at: nil, key: nil, kid: KID,
                issuer: self.issuer, audience: AUDIENCE, claims: {})
        payload = {
          "iss" => issuer,
          "aud" => audience,
          "sub" => subject,
          "account_id" => account_id,
          "scope" => Array(scopes).join(" "),
          "jti" => "jti-#{SecureRandom.hex(8)}",
          "iat" => (issued_at || 1.minute.ago).to_i,
          "exp" => (expires_at || 15.minutes.from_now).to_i
        }.merge(claims).compact

        JWT.encode(payload, key || private_key, "RS256", { kid: kid })
      end

      def expired_token(account_id: Account, **rest)
        token(account_id: account_id, expires_at: 1.minute.ago, issued_at: 1.hour.ago, **rest)
      end

      def foreign_token(account_id: Account, **rest)
        token(account_id: account_id, key: foreign_key, kid: FOREIGN_KID, **rest)
      end

      def with_verifier(verifier)
        previous = Identity::TokenVerifier.current
        Identity::TokenVerifier.current = verifier
        yield
      ensure
        Identity::TokenVerifier.current = previous
      end

      def install_default!
        ENV["BILLING_IDENTITY_ISSUER"] = issuer
        ENV["BILLING_IDENTITY_AUDIENCE"] = AUDIENCE
        Identity::TokenVerifier.current = verifier
      end

      def configuration
        { "BILLING_IDENTITY_ISSUER" => issuer, "BILLING_IDENTITY_AUDIENCE" => AUDIENCE }
      end

      def with_no_configuration
        previous_verifier = Identity::TokenVerifier.current
        previous_env = configuration
        begin
          previous_env.each_key { |name| ENV.delete(name) }
          Identity::TokenVerifier.current = Identity::TokenVerifier.new
          yield
        ensure
          previous_env.each { |name, value| ENV[name] = value }
          Identity::TokenVerifier.current = previous_verifier
        end
      end
    end

    Account = "33333333-3333-4333-8333-333333333333".freeze
    OtherAccount = "44444444-4444-4444-8444-444444444444".freeze
  end
end

module ActiveSupport
  class TestCase
    def auth_headers(account_id: TestSupport::TestIdentity::Account, **rest)
      { "Authorization" => "Bearer #{TestSupport::TestIdentity.token(account_id: account_id, **rest)}" }
    end
  end
end

ActionDispatch::IntegrationTest.class_eval do
  %i[get post patch put head delete].each do |verb|
    define_method(verb) do |path, **args|
      super(path, **args, headers: request_headers.merge(args[:headers] || {}))
    end
  end

  setup do
    @acting_account = nil
    @token_overrides = nil
    @raw_token = nil
    @raw_header = nil
  end

  def acts_as(account_id, **rest)
    @acting_account = account_id
    @token_overrides = rest
  end

  def without_token!
    @acting_account = false
  end

  def with_raw_token(token)
    @raw_token = token
  end

  def with_authorization_header(value)
    @raw_header = value
  end

  private
    def request_headers
      return {} if @acting_account == false
      return { "Authorization" => @raw_header } if @raw_header
      return { "Authorization" => "Bearer #{@raw_token}" } if @raw_token

      { "Authorization" => "Bearer #{TestSupport::TestIdentity.token(
        account_id: @acting_account || TestSupport::TestIdentity::Account,
        **(@token_overrides || {})
      )}" }
    end
end
