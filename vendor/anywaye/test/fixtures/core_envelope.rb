# frozen_string_literal: true

# A pinned copy of the parts of core's `schemas/event-envelope.schema.json` this
# library depends on, so the contract test has something to assert against in a
# checkout where `core` is not a sibling.
#
# Copied from `anywaye/core` at spec version 0.2.0 and checked against the real
# file on every run that has core on disk — `test/contract/core_specs_test.rb`
# compares the two and fails if they have drifted. This file is the fallback, not
# the source: a change to core's schema is made in core, and this copy follows.
module CoreEnvelope
  SPEC_VERSION = "1.0"

  ATTRIBUTES = %w[specversion id type source subject time data].freeze

  # `properties.subject.pattern` and its `minLength`/`maxLength`.
  SUBJECT_PATTERN = "^[A-Za-z0-9][A-Za-z0-9._:@/-]*$"
  SUBJECT_LENGTH = { "minLength" => 1, "maxLength" => 200 }.freeze

  # `$defs.eventType.pattern` and its bounds.
  EVENT_TYPE_PATTERN = '^[a-z][a-z0-9]*(-[a-z0-9]+)*\\.[a-z][a-z0-9]*(_[a-z0-9]+)*\\.[a-z][a-z0-9]*(_[a-z0-9]+)*$'
  EVENT_TYPE_LENGTH = { "minLength" => 5, "maxLength" => 120 }.freeze

  # `$defs.serviceName.pattern` and its bounds.
  SERVICE_NAME_PATTERN = "^[a-z][a-z0-9]*(-[a-z0-9]+)*$"
  SERVICE_NAME_LENGTH = { "minLength" => 2, "maxLength" => 40 }.freeze

  # The column list in `docs/event-outbox.md`, "The table", in order.
  OUTBOX_COLUMNS = %w[id event_type source subject time data created_at published_at attempts].freeze
end
