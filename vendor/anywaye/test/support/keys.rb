# frozen_string_literal: true

require "openssl"
require "jwt"

module TestSupport
  # Real RSA keys for the suite.
  #
  # Real, because the honest way to test signature verification is with real
  # keys: mocking the `jwt` gem would test the mock, and a verifier that has
  # only ever seen a fake RSA key has never been asked to reject a forged
  # signature. `testKey` is guard's `test/jwksServer.ts` idea in Ruby — mint a
  # key pair, publish the public half in the shape a JWKS carries, keep the
  # private half in this process and never let it out.
  #
  # 2048 bits, generated once per process. A test that generates a key per test
  # would spend more time in the RSA keygen than in the assertion.
  module Keys
    # 2048 bits. A shorter key is not faster in any useful sense here — the cost
    # is dominated by the keygen once per process, not by the verification — and
    # a test that ran against a 512-bit key would be testing a configuration
    # identity will never ship.
    BITS = 2048

    # A key pair plus the public JWK a JWKS would carry for it.
    Key = Struct.new(:kid, :private_key, :jwk, keyword_init: true)

    @cache = {}

    class << self
      # `kid` names the key, so rotation is `Keys.key("key-2")` and a test that
      # wants an unknown key id can ask for one that was never minted.
      def key(kid)
        @cache[kid] ||= mint(kid)
      end

      def mint(kid)
        pair = OpenSSL::PKey::RSA.generate(BITS)
        Key.new(kid: kid, private_key: pair, jwk: public_jwk(pair, kid))
      end

      # The public half, in the exact shape a JWKS document carries: `alg` and
      # `use` are what a real key set publishes, and a stand-in that omits them
      # is legal but says less — and the whole point of a stand-in is that it
      # cannot be more permissive than the thing it stands in for.
      def public_jwk(rsa, kid)
        # `JWT::JWK#export` hands back symbol keys; a JWKS document on the wire
        # has string keys, and the fetcher under test is parsing JSON, so the
        # stand-in has to be string-keyed to be honest about what it serves.
        exported = JWT::JWK.new(rsa.public_key).export.transform_keys(&:to_s)

        {
          "kty" => exported.fetch("kty"),
          "kid" => kid,
          "use" => "sig",
          "alg" => "RS256",
          "n" => exported.fetch("n"),
          "e" => exported.fetch("e")
        }
      end
    end
  end
end
