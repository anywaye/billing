# frozen_string_literal: true

require "json"
require "uri"

module Outbox
  # The transport: one envelope onto the fleet's JetStream bus.
  #
  # This is the only piece of the publisher that knows a broker exists, and it
  # is one method wide for the same reason identity's `Publisher` interface is:
  # the loop should not care what carries the bytes. Everything the transport
  # owns — connection handling, subject naming, the ack — is behind
  # `#publish`.
  #
  # ## Why JetStream and not core NATS
  #
  # `published_at` is set from the broker's acknowledgement, and only
  # JetStream's `publish` blocks until the broker answers. A core-NATS publish
  # returns when the bytes are on the wire — not when the broker has stored
  # them — so marking on its return would mark rows published that were never
  # delivered: an event announced and lost, which is the failure the outbox
  # exists to prevent. The ack *is* the contract, so the call is the contract.
  #
  # ## An unanswered publish is a failure, not a wait
  #
  # "Until the broker acks" is not "forever". `publish` is bounded by
  # `PUBLISH_TIMEOUT`: a broker that neither acks nor refuses — a
  # half-configured stream, a JetStream layer with no matching stream and no
  # core subscriber — returns an error instead of hanging the loop while it
  # holds the batch. A failure here raises, the shared gem's publisher counts
  # the row as failed and leaves it claimable, and the next pass retries it with
  # the same envelope id.
  #
  # ## A broker that is down is an outage, not a configuration error
  #
  # The outbox table is the durable store: rows accumulate while the broker is
  # away and drain when it returns. So a refused connection at boot is logged
  # and the loop still starts — every publish while the broker is down fails
  # fast, the rows stay claimable, and they leave when it comes back. What
  # *is* refused at boot is a URL that does not parse: that is a deployment
  # that believes it has a bus and does not.
  class NatsPublisher
    # Bounds the initial connection. Identity's `DefaultNATSConnectTimeout`: a
    # broker that is slow to answer, not one that is absent.
    CONNECT_TIMEOUT = 5

    # Bounds one publish's wait for the ack. Identity's
    # `DefaultPublishTimeout`. A full batch against a fully silent broker
    # therefore drains in at most 100 × 10s, loudly, with every row left
    # claimable — which is why the worst case is written down as a constant
    # rather than discovered in an incident.
    PUBLISH_TIMEOUT = 10

    # @param url [String] the broker, as `NATS_URL`.
    # @param logger [#info, #warn, nil] where refusals go. Never the payload.
    def self.build(url, logger: nil, connect_timeout: CONNECT_TIMEOUT, publish_timeout: PUBLISH_TIMEOUT)
      new(url, logger: logger, connect_timeout: connect_timeout, publish_timeout: publish_timeout)
    end

    def initialize(url, logger: nil, connect_timeout: CONNECT_TIMEOUT, publish_timeout: PUBLISH_TIMEOUT)
      @url = parse_url(url)
      @logger = logger
      @connect_timeout = positive(connect_timeout, "connect_timeout")
      @publish_timeout = positive(publish_timeout, "publish_timeout")
      @mutex = Mutex.new
      @client = nil
    end

    attr_reader :url

    # The deliverer's contract: one envelope hash in, and a return only once the
    # broker has it. Raising is how it refuses.
    #
    # The envelope hash is the shared gem's — core's seven attributes, with the
    # row's own id. The subject on the wire is the **type**, never the
    # envelope's `subject` attribute, which is the entity the event is about.
    def publish(envelope)
      type = envelope.fetch("type")
      deny_unless_ours(type)
      with_jetstream do |jetstream|
        jetstream.publish(type, JSON.generate(envelope), timeout: @publish_timeout)
      end
      nil
    end

    def connected?
      client = @mutex.synchronize { @client }
      !client.nil? && client.connected?
    end

    # Closes the broker connection. Safe after the loop has stopped, and safe to
    # call twice: the second close is a no-op.
    def close
      client = @mutex.synchronize { @client }
      client&.close
      @mutex.synchronize { @client = nil }
      nil
    end

    private

      # The URL is parsed at construction, and a URL that does not parse is a
      # boot failure. Distinguished from an unreachable broker, which is not:
      # see the class comment.
      def parse_url(url)
        text = url.to_s
        raise Outbox::ConfigurationError, "NATS_URL does not parse as a URL: #{text.inspect}" if text.empty?

        uri = URI.parse(text)
        raise Outbox::ConfigurationError, "NATS_URL has no host: #{text.inspect}" if uri.host.to_s.empty?

        uri
      rescue URI::InvalidURIError => error
        raise Outbox::ConfigurationError, "NATS_URL does not parse as a URL: #{text.inspect} (#{error.class})"
      end

      def with_jetstream
        client = connected_client
        yield client.jetstream
      end

      # The connection, re-established when it is gone. This is the Ruby
      # translation of identity's `RetryOnFailedConnect`: a broker that is down
      # when the process starts is not a startup failure, and a broker that goes
      # away mid-process is reconnected to on the next pass rather than by
      # taking the loop down.
      #
      # Serialised because the loop is the only caller in production but a
      # caller is not a guarantee, and two threads sharing one client is a
      # second reason for the mutex the client already has.
      def connected_client
        @mutex.synchronize do
          @client = nil if @client && !@client.connected?
          @client ||= connect
        end
      end

      def connect
        ::NATS.connect(@url.to_s, connect_timeout: @connect_timeout)
      rescue ::NATS::IO::ConnectError, ::NATS::IO::NoServersError => error
        # Not raised past here: the caller (the shared gem's publisher) records
        # the row as failed, and the next pass tries again. The broker being
        # down is an outage to log, not a reason to stop draining.
        @logger&.warn("outbox: the broker at #{@url.host}:#{@url.port} did not accept a connection (#{error.class})")
        raise
      end

      # The fleet rule: a publisher's event types start with its own name. This
      # service publishes `billing.*` and nothing else, enforced three times
      # already — `OutboxEvent::TYPES` at the write, the manifest, and core's
      # catalog — and this is the fourth place, because a type that reached the
      # wire unprefixed would land on a subject the `billing.>` stream does not
      # cover and vanish.
      def deny_unless_ours(type)
        return if type.start_with?("#{OutboxEvent::SERVICE}.")

        raise Outbox::Error, "refusing to publish #{type.inspect}: a billing event type starts with \"billing.\""
      end

      def positive(value, field)
        raise Outbox::ConfigurationError, "#{field} must be an integer >= 1" unless value.is_a?(Integer) && value >= 1

        value
      end
  end
end
