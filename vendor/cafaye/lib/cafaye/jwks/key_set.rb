# frozen_string_literal: true

require "jwt"

module Cafaye
  module Jwks
    # A parsed key set: `kid` to usable public key, and nothing else.
    #
    # Built from a JWKS document, and it refuses a document that is not one
    # before a single key is imported. An endpoint that answers 200 with a login
    # page, or with an HTML error from a misconfigured ingress, is the failure
    # this catches — and it has to be caught here, because the alternative is
    # importing nothing, treating every token as signed by an unknown key, and
    # turning an outage into a fleet-wide authentication failure that looks
    # exactly like a wave of forgeries.
    #
    # **Key material never leaves this object and is never logged.** The keys
    # live in an ivar with no public reader; the only way out is
    # `#verification_key_for`, which hands back one key for one `kid` and
    # nothing else. `#inspect` prints the key ids, which are public and are the
    # one thing about a key set worth a log line. `test/canary_test.rb` asserts
    # both.
    class KeySet
      # Only RSA signature keys are usable, because RS256 is the only algorithm
      # the verifier accepts. A key set that also publishes EC or oct keys is
      # normal, and those are skipped rather than refused: refusing the document
      # would make a perfectly good key set unusable.
      USABLE_KTY = "RSA"
      USABLE_USE = "sig"

      # The algorithms a published key may declare. Mirrors
      # `TokenVerifier::ALGORITHMS` and is repeated rather than referenced
      # because the verifier requires this file, and a constant that cannot be
      # read without loading the thing it constrains is not a constant.
      ALLOWED_ALGORITHMS = [ "RS256" ].freeze

      attr_reader :kids, :fetched_at

      # @param document [Object] the parsed JSON body, of whatever shape.
      # @param fetched_at [Time] when it was fetched, for the cache's own
      #   bookkeeping and for nothing else.
      def initialize(document, fetched_at:)
        @keys = index(document)
        @kids = @keys.keys.freeze
        @fetched_at = fetched_at
        freeze
      end

      def include?(kid)
        @keys.key?(kid)
      end

      # The verification key for `kid`, or `nil`. A lookup, not a policy: the
      # caller is the verifier, and it has already applied the algorithm
      # allowlist.
      def verification_key_for(kid)
        @keys[kid]
      end

      def size
        @keys.size
      end

      # Key ids only. Never the keys.
      def inspect
        "#<#{self.class.name} kids=#{@kids.inspect}>"
      end
      alias to_s inspect

      private

      def index(document)
        extract_keys(document).each_with_object({}) do |key, index|
          next unless usable?(key)

          index[key["kid"]] = import(key)
        end
      end

      def extract_keys(document)
        raise Errors::JwksUnavailable, "the signing keys could not be read" unless document.is_a?(Hash)

        keys = document["keys"]
        unless keys.is_a?(Array) && !keys.empty?
          raise Errors::JwksUnavailable, "the signing keys could not be read"
        end

        keys
      end

      # A key is usable when it says it is an RSA signature key. `alg` and `use`
      # are optional in RFC 7517 and a real key set usually publishes them, but
      # a set that omits them is not a set to refuse: the verifier's allowlist
      # decides the algorithm, and a key that omits `use` is not claiming to be
      # for encryption.
      def usable?(key)
        return false unless key.is_a?(Hash)
        return false unless key["kty"] == USABLE_KTY
        return false unless key["use"].nil? || key["use"] == USABLE_USE
        return false unless key["alg"].nil? || ALLOWED_ALGORITHMS.include?(key["alg"])
        return false unless key["kid"].is_a?(String) && !key["kid"].empty?

        true
      end

      def import(key)
        JWT::JWK.import(key).verify_key
      rescue JWT::JWKError, OpenSSL::PKey::PKeyError => error
        # The class of the failure, never the key and never the document: a
        # malformed JWKS can contain whatever a misconfigured endpoint put in
        # it, and this library does not put a published document in a message.
        raise Errors::JwksUnavailable, "a published key could not be imported (#{error.class})"
      end
    end
  end
end
