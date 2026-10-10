# frozen_string_literal: true

require "net/http"
require "uri"

module Cafaye
  module Jwks
    # The one place this library makes an outbound request.
    #
    # `Net::HTTP` rather than a client gem, for the same reason `jwt` is a
    # dependency and `faraday` is not: this is a GET of a public document with a
    # timeout, and a dependency that would earn its place has to own a contract
    # this repository would otherwise be hand-rolling. Net::HTTP owns TLS
    # verification, and it ships with the interpreter.
    #
    # It returns the *parsed* document and nothing else. It does not log the
    # body, it does not log the URL's query, and it does not put a response
    # header into an exception message — the caller gets a class and a status,
    # which is all a refusal needs and all that is safe to write down.
    class Transport
      # Seconds. The default, and the reason this gem's own tests are fast: a
      # key set that has not answered in five seconds is not going to answer,
      # and a request thread is worth more elsewhere.
      DEFAULT_TIMEOUT = 5

      # A body larger than this is not a key set. A JWKS for a platform is
      # kilobytes; anything approaching a megabyte is a captive portal, and
      # reading it into memory is a denial of service this library would
      # otherwise hand to whoever controls the network path.
      MAX_BODY_BYTES = 256 * 1024

      Result = Struct.new(:status, :body, keyword_init: true)

      def initialize(timeout: DEFAULT_TIMEOUT)
        @timeout = timeout
      end

      # @return [Result]
      # @raise [Cafaye::Errors::JwksUnavailable] for anything that is not a
      #   readable 200. The distinction between "identity is down" and "the token
      #   is bad" is this exception's whole job.
      def get(url)
        uri = URI.parse(url)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                     open_timeout: @timeout, read_timeout: @timeout) do |http|
          http.get(uri.request_uri)
        end

        return Result.new(status: response.code.to_i, body: response.body.to_s) if response.is_a?(Net::HTTPSuccess)

        raise Errors::JwksUnavailable, "the signing keys could not be retrieved (status #{response.code.to_i})"
      rescue URI::InvalidURIError, SystemCallError, IOError, Timeout::Error, SocketError, Net::ProtocolError => error
        # The class only. A `Net::HTTP` message can carry the URL, the host and
        # occasionally a fragment of the body, and this library's rule is that
        # nothing that touched the network goes in a message.
        raise Errors::JwksUnavailable, "the signing keys could not be retrieved (#{error.class})"
      end
    end
  end
end
