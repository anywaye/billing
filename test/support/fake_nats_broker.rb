# frozen_string_literal: true

require "json"
require "socket"

# An in-process NATS broker double, speaking enough of the wire protocol for
# the real `nats-pure` client to connect, request and be acknowledged.
#
# ## Why a double and not a mock
#
# The behaviour under test IS the wire: the subject a row is published on, the
# envelope bytes that arrive, and the row's columns after the broker acks. A
# mocked transport would prove the loop calls something; this proves what a
# consumer on the fleet's bus receives, against the real client and a real
# socket — only the broker is a double, because Ruby has no embedded
# nats-server (identity's Go tests use `nats-server/v2/server` in-process; the
# Ruby client ships no server, and the fleet's broker is a container).
#
# What it speaks: INFO on connect, PONG for PING, SUB/UNSUB bookkeeping, and PUB
# with a reply subject answered the way JetStream answers it — a plain
# `MSG ... +ACK {...}` for a subject a stream covers, and an `HMSG ... 503` for
# one that no stream covers (`NoRespondersError`, which the client's
# `JetStream#publish` turns into `NoStreamResponse`). A third mode, silent,
# answers nothing, which is what makes a publish *time out*.
#
# It is deliberately small: it is a broker, not a fleet.
class FakeNatsBroker
  # The acks it answers with. Shaped like a JetStream PubAck because that is the
  # contract the transport's caller relies on: the stream that accepted it, and
  # the sequence number it was stored under. Bare JSON and not core NATS'
  # `+ACK` preface: `JetStream#publish` parses the reply payload as JSON, and a
  # preface is a parse error at every consumer.
  ACK = '{"stream":"CAFAYE","seq":%d,"duplicate":false}'

  INFO = {
    server_id: "fake-broker",
    server_name: "fake",
    version: "0.0.0",
    host: "127.0.0.1",
    port: 4222,
    auth_required: false,
    tls_required: false,
    max_payload: 1_048_576,
    headers: true,
    jetstream: true,
    client_id: 1,
    proto: 1
  }.to_json

  # @param stream_subjects [Array<String>] the subjects a stream covers. Supports
  #   the `>` wildcard, so `["billing.>"]` is the fleet filter and not a special
  #   case. A publish to a subject no stream covers is refused with a 503, the
  #   way the real broker refuses it — which is the production failure the
  #   stack's missing stream would produce.
  # @param mode [:ack, :silent] how a covered subject is answered. `:silent` is
  #   the broker that neither acks nor refuses — a half-configured stream — and
  #   it is what makes a publish time out.
  def initialize(stream_subjects: [], mode: :ack)
    @stream_subjects = stream_subjects
    @mode = mode
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @sequence = 0
    @mutex = Mutex.new
    @delivered = []
    @connections = []
    @acceptor = nil
    @shutdown = false
  end

  attr_reader :port

  def url
    "nats://127.0.0.1:#{@port}"
  end

  def start
    @acceptor = Thread.new do
      loop do
        client = @server.accept
        @mutex.synchronize { @connections << Thread.new(client) { |socket| serve(socket) } }
      rescue IOError, Errno::EBADF
        break
      end
    end
    self
  end

  # Every publish the broker received, in arrival order: `{subject:, payload:}`.
  # The payload is the exact bytes a consumer would read.
  def delivered
    @mutex.synchronize { @delivered.dup }
  end

  def shutdown
    @shutdown = true
    @server.close rescue nil
    @acceptor&.kill
    @acceptor&.join(1)
    @mutex.synchronize do
      @connections.each { |thread| thread.kill if thread.alive? }
      @connections.clear
    end
    self
  end

  private

    def serve(socket)
      socket.write("INFO #{INFO}\r\n")
      buffer = +""
      subscriptions = {}
      until @shutdown
        line = read_line(socket, buffer)
        break if line == :eof

        case line
        when /\ACONNECT\s/ then nil
        when /\APING\z/ then reply(socket, "PONG\r\n")
        when /\APONG\z/ then nil
        when /\ASUB\s+(\S+)\s+(\d+)/
          subscriptions[Regexp.last_match(2)] = Regexp.last_match(1)
        when /\AUNSUB\s+(\d+)/
          subscriptions.delete(Regexp.last_match(1))
        when /\APUB\s+(\S+)(?:\s+(\S+))?\s+(\d+)\z/
          subject = Regexp.last_match(1)
          reply_to = Regexp.last_match(2)
          payload = read_exact(socket, buffer, Integer(Regexp.last_match(3)))
          break if payload == :eof

          record(subject, payload)
          answer(socket, reply_to, subscriptions, subject)
        else
          break
        end
      end
    rescue IOError, Errno::ECONNRESET
      nil
    ensure
      socket.close rescue nil
    end

    # The answer JetStream would give. A covered subject is acked; a subject no
    # stream covers is refused with the 503 no-responders status, which is the
    # direction a misconfigured stack must fail in — the row stays claimable
    # with attempts climbing, and the event leaves the table only once a stream
    # exists that covers its subject.
    def answer(socket, reply_to, subscriptions, subject)
      return if reply_to.nil? || reply_to.empty?
      return unless (sid = sid_for(subscriptions, reply_to))

      if !covers?(subject)
        header = "NATS/1.0 503 No Responders\r\n\r\n"
        return reply(socket, "HMSG #{reply_to} #{sid} #{header.bytesize} #{header.bytesize}\r\n#{header}\r\n")
      end
      return if @mode == :silent

      ack = format(ACK, @mutex.synchronize { @sequence += 1 })
      reply(socket, "MSG #{reply_to} #{sid} #{ack.bytesize}\r\n#{ack}\r\n")
    end

    # The sid subscribed to `subject`, or nil. Wildcards are matched rather than
    # compared: the JetStream client requests on an ephemeral inbox it
    # subscribed to with a `*`, and a broker that only answered exact matches
    # would ack nothing.
    def sid_for(subscriptions, subject)
      subscriptions.each do |sid, filter|
        return sid if subject_matches?(filter, subject)
      end
      nil
    end

    # Enough of NATS' subject language for the two wildcards this double needs:
    # `*` for one token, `>` for the rest.
    def subject_matches?(filter, subject)
      return true if filter == subject

      tokens = filter.split(".")
      parts = subject.split(".")
      tokens.each_with_index do |token, index|
        return true if token == ">"
        return false if index >= parts.size || (token != "*" && token != parts[index])
      end
      tokens.size == parts.size
    end

    def record(subject, payload)
      @mutex.synchronize { @delivered << { subject: subject, payload: payload.dup } }
    end

    def reply(socket, text)
      socket.write(text)
    rescue IOError, Errno::EPIPE
      nil
    end

    def read_line(socket, buffer)
      while (index = buffer.index("\r\n")).nil?
        chunk = socket.readpartial(4096)
        return :eof if chunk.nil?

        buffer << chunk
      end
      buffer.slice!(0, index + 2).delete_suffix("\r\n")
    end

    def read_exact(socket, buffer, size)
      while buffer.bytesize < size
        chunk = socket.readpartial([ size - buffer.bytesize, 4096 ].min)
        return :eof if chunk.nil?

        buffer << chunk
      end
      buffer.slice!(0, size).tap { read_line(socket, buffer) }
    end

    # The fleet filter: `billing.>` matches `billing.<anything>`, and a subject
    # with no wildcard matches itself. Enough of NATS' subject language for a
    # stream that filters one service's events.
    def covers?(subject)
      @stream_subjects.any? do |filter|
        if filter.end_with?(">")
          subject.start_with?(filter.delete_suffix(">"))
        else
          subject == filter
        end
      end
    end
end
