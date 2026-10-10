# frozen_string_literal: true

require "time"
require "json"

module Cafaye
  module Outbox
    # One event, as core's `schemas/event-envelope.schema.json` defines it.
    #
    # Every pattern below is copied from core's schema rather than invented, and
    # `test/contract/core_specs_test.rb` asserts the copies are the same
    # grammar. The duplication is the point: a malformed envelope is refused at
    # the one place that wrote it, rather than failing at every consumer on the
    # platform — which is where a format error is most expensive to find, and
    # where a consumer that has to be fixed is a consumer that has to be
    # redeployed.
    #
    # The object is frozen and its `data` is frozen, because this envelope is
    # published to everyone: a payload mutated after the row was written is a
    # payload that is on the bus and not the one that was validated.
    class Envelope
      # core's `specversion` const. Increments only for a breaking envelope
      # change; a new attribute is a major bump, not a new value.
      SPEC_VERSION = "1.0"

      # The claims are a closed set, and `additionalProperties` is `false`, so an
      # undeclared attribute is an error at every consumer rather than a silent
      # no-op. This list is the whole envelope.
      ATTRIBUTES = %w[specversion id type source subject time data].freeze

      # core's `eventType` pattern, verbatim from the schema. The first segment
      # is a cafaye service name and is kebab-case, so it may contain a dash and
      # never an underscore; the entity and action segments are snake_case.
      TYPE_PATTERN = /\A[a-z][a-z0-9]*(-[a-z0-9]+)*\.[a-z][a-z0-9]*(_[a-z0-9]+)*\.[a-z][a-z0-9]*(_[a-z0-9]+)*\z/

      # core's `serviceName` pattern. A service name never contains a dot, so
      # this also catches a `source` that is really a full event type.
      SOURCE_PATTERN = /\A[a-z][a-z0-9]*(-[a-z0-9]+)*\z/

      # core's `subject` pattern. The subject is the entity the event is about,
      # and it is interpolated into consumer logs and routing keys, so the
      # character set is deliberately narrow. The character class is written
      # exactly as core's schema writes it, `-` last, so the contract test can
      # compare the two as strings.
      SUBJECT_PATTERN = %r{\A[A-Za-z0-9][A-Za-z0-9._:@/-]*\z}

      # core's length bounds.
      TYPE_LENGTH = (5..120).freeze
      SUBJECT_LENGTH = (1..200).freeze
      SOURCE_LENGTH = (2..40).freeze

      # RFC3339 uuid. The schema says `format: uuid`; this is the shape that
      # format means, anchored.
      UUID_PATTERN = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

      # The subject every event with no single entity uses. A required field
      # with a reserved value is a value a consumer can always read; a missing
      # field is a null check every consumer has to remember to write.
      PLATFORM_SUBJECT = "platform"

      attr_reader :id, :type, :source, :subject, :time, :data

      # @raise [Cafaye::Errors::Outbox::EnvelopeInvalid] for anything core's
      #   schema would reject. Validated on construction so an invalid envelope
      #   is a value that cannot exist, rather than a hash that has to be checked
      #   everywhere it is used.
      def initialize(id:, type:, source:, subject:, time:, data:)
        @id = parse_id(id)
        # `source` before `type`, because the type is checked against it: a type
        # that is not prefixed by its own publisher is the one error that no
        # amount of downstream care catches.
        @source = parse_source(source)
        @type = parse_type(type)
        @subject = parse_subject(subject)
        @time = parse_time(time)
        @data = parse_data(data)
        freeze
      end

      # The envelope as it goes on the wire, and as core's schema describes it:
      # CloudEvents 1.0 attribute names, cafaye's required subset, nothing else.
      def to_h
        {
          "specversion" => SPEC_VERSION,
          "id" => @id,
          "type" => @type,
          "source" => @source,
          "subject" => @subject,
          "time" => @time.utc.iso8601,
          "data" => @data
        }.freeze
      end

      def specversion
        SPEC_VERSION
      end

      def ==(other)
        other.is_a?(Envelope) && other.to_h == to_h
      end
      alias eql? ==

      def hash
        to_h.hash
      end

      # The data is printed, never the id-and-type-and-subject preamble, and
      # never anything that is not one of this class's seven attributes. The
      # payload is the one part of an envelope that can carry a value, and
      # `inspect` is a logging surface.
      def inspect
        "#<#{self.class.name} type=#{@type.inspect} subject=#{@subject.inspect} " \
          "time=#{@time.utc.iso8601} data=#{@data.inspect}>"
      end

      private

      def parse_id(value)
        text = value.to_s
        invalid("id", "is not a uuid") unless UUID_PATTERN.match?(text)

        text
      end

      def parse_type(value)
        text = value.to_s
        unless TYPE_LENGTH.cover?(text.length) && TYPE_PATTERN.match?(text)
          invalid("type", "is not <service>.<entity>.<action>")
        end
        # The prefix is not optional and it is not decorative: it is what lets a
        # type be routed, generated and fanned out from the string alone, and a
        # type whose `source` is not its own first segment is a type two
        # consumers would route differently.
        invalid("type", "is not prefixed by its own source") unless text.start_with?("#{@source}.")

        text
      end

      def parse_source(value)
        text = value.to_s
        unless SOURCE_LENGTH.cover?(text.length) && SOURCE_PATTERN.match?(text)
          invalid("source", "is not a cafaye service name")
        end

        text
      end

      def parse_subject(value)
        text = value.to_s
        unless SUBJECT_LENGTH.cover?(text.length) && SUBJECT_PATTERN.match?(text)
          invalid("subject", "is not an entity identifier")
        end

        text
      end

      # `format: date-time` is RFC3339, and a local offset satisfies it while
      # making every consumer's comparison wrong. The column is `timestamptz`
      # and the wire format is UTC, always.
      def parse_time(value)
        time = value.is_a?(Time) ? value.utc : nil
        invalid("time", "is not a time") if time.nil?

        time
      end

      # A jsonb column that holds a scalar is a payload no contract test can
      # reach inside and no query can select from, and `jsonb` rather than `json`
      # is what makes two identical payloads byte-identical. core's schema allows
      # a scalar `data` in principle; cafaye's per-event payload schemas are all
      # objects, and an object is what the table's CHECK constraint requires.
      def parse_data(value)
        invalid("data", "is not an object") unless value.is_a?(Hash)
        invalid("data", "has a key that is not a string") unless value.keys.all?(String)

        value.each_with_object({}) { |(key, entry), frozen| frozen[key] = entry }.freeze
      end

      def invalid(attribute, because)
        raise Errors::Outbox::EnvelopeInvalid, "envelope #{attribute} #{because}"
      end
    end
  end
end
