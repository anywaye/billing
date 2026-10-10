# frozen_string_literal: true

require "securerandom"

module Cafaye
  module Outbox
    # Writes an event into `outbox_events`, inside the caller's transaction.
    #
    # This is the second of the two things this gem exists to stop being
    # hand-written, and its one non-negotiable rule is core's
    # (`docs/event-outbox.md`): **a service never publishes an event outside a
    # transaction that also wrote the domain state it describes.** The insert
    # goes into the caller's transaction, and `publish!` refuses to write when
    # there is not one.
    #
    #   Cafaye::Outbox::Writer.new(connection: connection, service_name: "billing").then do |outbox|
    #     Customer.transaction do
    #       customer = Customer.create!(...)
    #       outbox.publish!(
    #         type: "billing.customer.created",
    #         subject: customer.id,
    #         data: { "customer_id" => customer.id }
    #       )
    #     end
    #   end
    #
    # The writer never opens, commits or rolls back a transaction of its own. It
    # has no `transaction` method, so the pairing cannot be broken by a caller
    # reaching for the wrong one, and a test asserts the connection's
    # transaction state is unchanged across a call.
    class Writer
      # Events this process has written. A counter rather than a log line,
      # because the number is the thing an operator wants and a log line about a
      # successful write is noise.
      attr_reader :events_written

      # @param connection [PgConnection, ActiveRecordConnection] something that
      #   can say whether it is in a transaction and insert a row.
      # @param service_name [String] this service's namespace name, which is
      #   also `source` on every envelope and the first segment of every `type`.
      # @param payload_validators [Hash{String => #call}] optional, keyed by
      #   event type, called with the `data` before the insert. core's checklist
      #   asks for the payload to be validated against
      #   `schemas/events/<type>.schema.json` before the insert; this gem takes a
      #   callable rather than carrying a JSON Schema validator of its own. See
      #   the DECISION NEEDED in cafaye.yml.
      def initialize(connection:, service_name:, clock: -> { Time.now },
                     payload_validators: {}, require_transaction: true,
                     id_generator: -> { SecureRandom.uuid })
        @connection = connection
        @service_name = Envelope::SOURCE_PATTERN.match?(service_name.to_s) ? service_name.to_s : reject_service(service_name)
        @clock = clock
        @payload_validators = payload_validators.freeze
        @require_transaction = require_transaction
        @id_generator = id_generator
        @events_written = 0
      end

      # @param type [String] `<service>.<entity>.<action>`.
      # @param subject [String] the entity the event is *about*, not the actor,
      #   or the literal `platform` for an event with no single entity.
      # @param data [Hash] the payload, with string keys.
      # @param time [Time, nil] when the state changed, not when the row is
      #   written. A keyword rather than always-`Time.now` because not every
      #   state change is made by this process: a webhook describes something a
      #   processor did seconds or days ago, and stamping it with the moment the
      #   row was written would make out-of-order delivery undetectable, because
      #   every event would then appear to have happened in the order it
      #   arrived.
      # @param id [String, nil] an explicit envelope id, for the rare caller that
      #   needs a specific one — a replay from an external system whose event id
      #   is its own. Omitted by almost everyone, and then a fresh UUID is minted
      #   per call, which is the guarantee: a retry of the same logical event
      #   re-runs this method and gets a new id, so a consumer's dedupe key does
      #   not drop the second attempt as a duplicate of the first. The publisher
      #   loop never passes one; it republishes the row's own.
      # @return [Cafaye::Outbox::Envelope] the envelope that was written.
      def publish!(type:, subject:, data: {}, time: nil, id: nil)
        # The one check the whole table depends on. `require_transaction: false`
        # exists for the caller who genuinely owns the transaction some other
        # way — a service whose domain write is a stored procedure, say — and it
        # is a decision recorded somewhere, not a convenience.
        if @require_transaction && !@connection.in_transaction?
          raise Errors::Outbox::NotInTransaction,
                "publish! must be called inside the transaction that wrote the state it describes"
        end

        envelope = Envelope.new(
          id: id || @id_generator.call,
          type: type,
          source: @service_name,
          subject: subject,
          time: time || @clock.call,
          data: data
        )

        validate_payload!(envelope)

        @connection.insert(envelope)
        @events_written += 1
        envelope
      end

      # The service name on every envelope this writer produces.
      def service_name
        @service_name
      end

      private

      # Run before the insert, not after: a payload that is refused has to leave
      # no row behind, and "validate then insert" is the only order in which
      # that is true even if the caller's transaction later rolls back for an
      # unrelated reason.
      def validate_payload!(envelope)
        validator = @payload_validators[envelope.type]
        return if validator.nil?

        validator.call(envelope.data)
      rescue StandardError => error
        # The class and the message, and neither of them can carry a token, a
        # claim or a key. A payload validator is caller-supplied, so its message
        # is the caller's to keep small — this is where that advice is enforced
        # rather than merely given.
        raise Errors::Outbox::EnvelopeInvalid,
              "envelope data for #{envelope.type} was refused by its validator (#{error.class})"
      end

      def reject_service(service_name)
        raise Errors::ConfigurationError,
              "service_name must be a cafaye service name, got #{service_name.to_s.inspect}"
      end
    end
  end
end
