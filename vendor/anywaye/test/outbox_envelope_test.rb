# frozen_string_literal: true

require_relative "test_helper"

# The envelope, which is core's `schemas/event-envelope.schema.json` and not
# this library's opinion of it.
#
# Every pattern in `Anywaye::Outbox::Envelope` is copied from core's schema, and
# `test/contract/core_specs_test.rb` asserts the copies are the same grammar.
# The duplication is the point: a malformed type is refused at the one place
# that wrote it rather than at every consumer on the platform, and that only
# works if the writer holds the same grammar core does.
class OutboxEnvelopeTest < TestSupport::Test
  ID = "0198f1c2-7a41-7c3b-9d55-2f0b6a1e4c88"

  def test_it_carries_exactly_the_attributes_core_declares
    envelope = build

    assert_equal(
      %w[data id source specversion subject time type],
      envelope.to_h.keys.sort
    )
  end

  def test_the_dialect_is_pinned_to_core_s_value
    assert_equal("1.0", build.specversion)
  end

  def test_the_id_is_a_uuid
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, build.id)
  end

  def test_the_time_is_rfc3339_in_utc
    # `format: date-time` is RFC3339, and a local offset satisfies it while
    # making every consumer's comparison wrong. UTC only.
    envelope = build(time: Time.utc(2026, 9, 30, 4, 19, 0))

    assert_equal("2026-09-30T04:19:00Z", envelope.to_h.fetch("time"))
  end

  def test_a_non_utc_time_is_converted_rather_than_carried_through
    envelope = build(time: Time.new(2026, 9, 30, 6, 19, 0, "+02:00"))

    assert_equal("2026-09-30T04:19:00Z", envelope.to_h.fetch("time"))
  end

  def test_the_data_is_the_payload_and_nothing_else
    assert_equal(
      { "customer_id" => "cus_01J9Z8QK5M4N7P2R3T6V8W9X0A", "email" => "a@example.test" },
      build.to_h.fetch("data")
    )
  end

  def test_it_refuses_a_type_that_is_not_three_segments
    error = assert_raises(Anywaye::Errors::Outbox::EnvelopeInvalid) { build(type: "customer.created") }

    assert_match(/type/, error.message)
  end

  def test_it_refuses_a_type_whose_service_segment_has_an_underscore
    # A service name is kebab-case and never contains an underscore, so an
    # underscore in the first segment is always a mistake. `guard`'s sibling
    # implementation in `identity` gets this wrong today, with a pattern that
    # accepts two or three segments and snake_case service names.
    assert_raises(Anywaye::Errors::Outbox::EnvelopeInvalid) { build(type: "my_service.customer.created") }
  end

  def test_it_refuses_a_type_that_is_not_prefixed_by_its_own_source
    # The prefix is what lets a type be routed from the string alone. A row
    # whose `source` is not the first segment of its `type` is a row two
    # consumers would route differently and nobody downstream would notice.
    assert_raises(Anywaye::Errors::Outbox::EnvelopeInvalid) { build(type: "courier.customer.created", source: "billing") }
  end

  def test_it_refuses_a_source_that_is_not_a_service_name
    assert_raises(Anywaye::Errors::Outbox::EnvelopeInvalid) { build(source: "Billing") }
  end

  def test_it_refuses_an_empty_subject
    assert_raises(Anywaye::Errors::Outbox::EnvelopeInvalid) { build(subject: "") }
  end

  def test_it_refuses_a_subject_that_is_not_an_entity_identifier
    # A subject that carried transport metadata — a trace id, a retry count, a
    # sentence — would be a place for envelope and header state to disagree.
    assert_raises(Anywaye::Errors::Outbox::EnvelopeInvalid) { build(subject: "created by the api at 12:00") }
  end

  def test_it_refuses_a_subject_longer_than_core_allows
    assert_raises(Anywaye::Errors::Outbox::EnvelopeInvalid) { build(subject: "a" * 201) }
  end

  def test_it_accepts_the_reserved_platform_subject
    # A required field with a reserved value is a value a consumer can always
    # read; a missing field is a null check every consumer has to remember to
    # write. It has to match the pattern like any other identifier.
    assert_equal("platform", build(subject: "platform").subject)
  end

  def test_it_refuses_data_that_is_not_an_object
    assert_raises(Anywaye::Errors::Outbox::EnvelopeInvalid) { build(data: %w[a b]) }
    assert_raises(Anywaye::Errors::Outbox::EnvelopeInvalid) { build(data: nil) }
  end

  def test_it_refuses_data_with_a_key_that_is_not_a_string
    # jsonb round-trips a symbol key to a string, so a symbol-keyed payload
    # would be written to the table and read back as something else.
    error = assert_raises(Anywaye::Errors::Outbox::EnvelopeInvalid) { build(data: { customer_id: "cus_1" }) }

    assert_match(/string/i, error.message)
  end

  def test_it_refuses_a_subject_with_a_newline
    # Anchored with `\A` and `\z` rather than `^` and `$`, which in a Ruby
    # Regexp anchor to a line rather than to the string. Narrower than core's
    # JSON Schema pattern, and the safe direction: an envelope cannot be
    # smuggled through by appending a second line.
    refute Anywaye::Outbox::Envelope::SUBJECT_PATTERN.match?("cus_1\ntrace_id: x")
    refute Anywaye::Outbox::Envelope::TYPE_PATTERN.match?("billing.plan.created\nrm -rf /")
  end

  def test_it_is_frozen_and_its_data_is_frozen
    envelope = build

    assert_predicate(envelope, :frozen?)
    assert_predicate(envelope.data, :frozen?)
  end

  def test_two_envelopes_with_the_same_attributes_are_equal
    assert_equal(build, build)
  end

  def test_an_envelope_built_with_a_given_id_keeps_that_id
    # The publisher republishes a row, and the id it republishes is the one the
    # row already carries. That is what makes a consumer's dedupe key dedupe.
    assert_equal(ID, build(id: ID).id)
  end

  private

  def build(**overrides)
    Anywaye::Outbox::Envelope.new(**{
      id: ID,
      type: "billing.customer.created",
      source: "billing",
      subject: "cus_01J9Z8QK5M4N7P2R3T6V8W9X0A",
      time: now,
      data: { "customer_id" => "cus_01J9Z8QK5M4N7P2R3T6V8W9X0A", "email" => "a@example.test" }
    }.merge(overrides))
  end
end
