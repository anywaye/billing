# frozen_string_literal: true

require "json"

module Cafaye
  module Jwks
    # Fetches and parses a key set. One fetch, one parse, one `KeySet`.
    #
    # It is separate from the cache because those are two different jobs and
    # conflating them is how a refresh budget turns into a refresh per request:
    # the cache decides *whether* to fetch, and this decides *what a fetch is
    # worth*. Keeping them apart is also what lets a test drive the cache's
    # arithmetic with a fetcher that counts calls, and drive the parsing with a
    # transport that returns a body.
    class Fetcher
      def initialize(transport:, url:, clock:)
        @transport = transport
        @url = url
        @clock = clock
      end

      # @return [Cafaye::Jwks::KeySet]
      # @raise [Cafaye::Errors::JwksUnavailable] for a non-200, a body over the
      #   cap, unparseable JSON, or a document that is not a key set.
      def fetch
        result = @transport.get(@url)
        raise Errors::JwksUnavailable, "the signing keys could not be read (over #{Transport::MAX_BODY_BYTES} bytes)" if
          result.body.bytesize > Transport::MAX_BODY_BYTES

        KeySet.new(parse(result.body), fetched_at: @clock.call)
      end

      private

      def parse(body)
        JSON.parse(body)
      rescue JSON::ParserError
        # Not the parser's message: `JSON::ParserError` quotes the offending
        # bytes, and those bytes are whatever a proxy put in front of identity.
        raise Errors::JwksUnavailable, "the signing keys could not be read (not JSON)"
      end
    end
  end
end
