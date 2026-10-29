# frozen_string_literal: true

require "json"
require "socket"

class FakeNatsBroker
  ACK = '{"stream":"ANYWAYE","seq":%d,"duplicate":false}'

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

    def sid_for(subscriptions, subject)
      subscriptions.each do |sid, filter|
        return sid if subject_matches?(filter, subject)
      end
      nil
    end

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
