# frozen_string_literal: true

require "socket"
require "json"

module TestSupport
  # A stand-in for identity's JWKS endpoint, over real HTTP on an ephemeral port.
  #
  # It is a real socket server rather than a stubbed transport for the same
  # reason the keys are real: the things this suite proves about the fetcher —
  # that a rotation is picked up, that a 500 leaves the previous key set in
  # place, that an answer which is 200 and not a key set is refused — are all
  # properties of the code path a real request takes. A transport double would
  # let the fetcher pass tests it has not earned.
  #
  # It records every path it was asked for, so a test can assert the *number* of
  # outbound requests. That assertion is the one that matters for the refresh
  # budget: a verifier that fetches per request is correct and is a denial of
  # service aimed at identity, and only a count catches it.
  class JwksServer
    @running = []

    class << self
      def all_running
        @running
      end

      def track(server)
        @running << server
        server
      end
    end

    attr_reader :port, :requests

    # `keys` are `TestSupport::Keys::Key` values; the server publishes their
    # public halves and nothing else, because a JWKS that leaked a private key
    # would make the rotation tests prove nothing.
    def initialize(*keys, path: "/.well-known/jwks.json")
      @keys = keys
      @path = path
      @requests = []
      @mode = :keys
      @status = 500
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @thread = Thread.new { serve }
      @thread.abort_on_exception = false
      self.class.track(self)
    end

    def issuer
      "http://127.0.0.1:#{port}"
    end

    def jwks_url
      "#{issuer}#{@path}"
    end

    def publish(*keys)
      @keys = keys
      self
    end

    # Answers `status` with a body that is not a key set. This is identity being
    # down, or an endpoint that is configured wrong, and it is the case the
    # verifier must not turn into "your token is bad".
    def fail_with(status)
      @mode = :status
      @status = status
      self
    end

    # Answers 200 with something that is not a key set — the login page behind a
    # misconfigured ingress, the shape this is here to catch.
    def serve_garbage
      @mode = :garbage
      self
    end

    def serve_keys
      @mode = :keys
      self
    end

    def stop
      @server.close unless @server.closed?
      @thread&.join(2)
      self.class.all_running.delete(self)
      self
    rescue IOError, Errno::EBADF
      self
    end

    # How many times the key set was asked for. One fetch per rotation is the
    # budget; a number here above one is a bug with a name.
    def fetch_count
      @requests.count(@path)
    end

    private

    def serve
      loop do
        socket = @server.accept
        handle(socket)
      end
    rescue IOError, Errno::EBADF, Errno::ECONNRESET
      nil
    end

    def handle(socket)
      request_line = socket.gets
      # Drain the headers, so the client sees a complete exchange and does not
      # wait for us to read the rest of its request.
      while (line = socket.gets) && line != "\r\n"; end

      path = request_line.to_s.split(" ")[1].to_s
      @requests << path

      socket.print(response_for(path))
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      nil
    ensure
      socket.close
    end

    def response_for(path)
      return not_found unless path == @path

      case @mode
      when :status then text_response(@status, "upstream is unwell")
      when :garbage then text_response(200, "<html>login required</html>", "text/html")
      else json_response(200, { keys: @keys.map(&:jwk) })
      end
    end

    def not_found
      text_response(404, "not found")
    end

    def json_response(status, body)
      text_response(status, JSON.generate(body), "application/json")
    end

    def text_response(status, body, content_type = "text/plain")
      reason = { 200 => "OK", 404 => "Not Found", 500 => "Internal Server Error" }.fetch(status, "Error")
      [
        "HTTP/1.1 #{status} #{reason}\r\n",
        "content-type: #{content_type}\r\n",
        "content-length: #{body.bytesize}\r\n",
        "connection: close\r\n",
        "\r\n",
        body
      ].join
    end
  end
end
