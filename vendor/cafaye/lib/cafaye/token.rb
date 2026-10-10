# frozen_string_literal: true

require "openssl"
require "digest"

module Cafaye
  # A bearer token, which will not print itself.
  #
  # Not a `String` and not a subclass of one. That is the whole design, and it
  # is `muse`'s design in `src/muse/redaction.py`: subclassing `str` leaks
  # through every C-level string operation, and a plain object that is not a
  # `String` has no implicit conversion into a message, a log line, an `Array#join`
  # or a `problem+json` body. `%s`, f-strings, `to_s`, `inspect` and `+` all
  # produce the redaction marker.
  #
  # The rule this enforces is *none of it, ever* — not "the first eight
  # characters", not "everything after the last dot". A truncation rule is not a
  # redaction rule: eight characters of a bearer token are eight characters of a
  # bearer token, and "we only log a prefix" is the exact reasoning that ends
  # with a credential sitting in a searchable log index. The canary test in
  # `test/canary_test.rb` is what holds that line.
  #
  # `reveal` is the only way to read the value, so every read is greppable and a
  # review of "where is the credential read" is a `grep` rather than an argument.
  class Token
    # Obviously not a value, so a redacted log line is never mistaken for a
    # working credential.
    REDACTED = "[REDACTED]"

    # How much of a fingerprint to keep. Enough to make a 64-bit collision
    # irrelevant for a per-process correlation id, short enough that it reads as
    # an id rather than as a key.
    FINGERPRINT_LENGTH = 16

    # @param value [String] the compact serialisation, as it arrived.
    def initialize(value)
      @value = value.to_s
      freeze
    end

    def to_s
      REDACTED
    end

    def inspect
      "#<#{self.class.name} #{REDACTED}>"
    end

    # A stable, non-invertible handle for correlating refusals about one
    # credential without ever writing the credential.
    #
    # Safe because it is a truncated SHA-256 over a high-entropy serialisation:
    # it cannot be inverted, and a holder of the log cannot spend it. It is a
    # *correlation* id, not a credential, and the library writes it nowhere by
    # itself — a caller who wants it asks for it.
    def fingerprint
      Digest::SHA256.hexdigest(@value)[0, FINGERPRINT_LENGTH]
    end

    # The raw value. Every call to this is a place worth reviewing, which is the
    # property that makes the type worth having at all.
    def reveal
      @value
    end

    def empty?
      @value.empty?
    end

    def length
      @value.length
    end
  end
end
