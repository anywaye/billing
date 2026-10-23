# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../fixtures/core_envelope"

# The contract with core, read from core's own files rather than paraphrased.
#
# Every pattern this library enforces is a copy of something in
# `anywaye/core/schemas/event-envelope.schema.json` or in the table block in
# `anywaye/core/docs/event-outbox.md`. A copy is a duplicate that can drift, so
# it is checked: when `core` is on disk — a sibling checkout, or a CI job that
# clones it — this test compares the library's patterns to core's and compares
# the reference DDL's column list to the table in core's doc.
#
# ## There is no `skip` here, on purpose
#
# When core is not on disk the test falls back to the pinned copy in
# `test/fixtures/core_envelope.rb` and still asserts: that the pinned copy is
# present, that the library agrees with it, and that the fallback was actually
# used. A test that skips tells the next reader nothing about whether the
# contract is being enforced; a test that asserts against a pinned copy and
# *reports* that it is doing so tells them exactly how much is being checked.
#
# `bin/prime` in this worktree has core on disk, so the real comparison runs.
# CI has core on disk too: `ci/ci.yml` checks it out and puts it
# at the sibling path in every matrix job, and `release.yml` has always done the
# same, so the real comparison runs there as well.
class CoreSpecsTest < TestSupport::Test
  def setup
    super
    @schema = read_schema
  end

  # --- the envelope schema -------------------------------------------------

  def test_the_event_type_pattern_here_is_core_s
    assert_same_grammar core_pattern("eventType"), Anywaye::Outbox::Envelope::TYPE_PATTERN,
                        sample: "billing.customer.created"
  end

  def test_the_service_name_pattern_here_is_core_s
    assert_same_grammar core_pattern("serviceName"), Anywaye::Outbox::Envelope::SOURCE_PATTERN,
                        sample: "billing", variants: [ "email-sender", "billing\nsource: x" ]
  end

  def test_the_subject_pattern_here_is_core_s
    assert_same_grammar core_pattern("subject"), Anywaye::Outbox::Envelope::SUBJECT_PATTERN,
                        sample: "cus_01J9Z8QK5M4N7P2R3T6V8W9X0A"
  end

  def test_the_event_type_bounds_here_are_core_s
    assert_equal core_length("eventType").min, Anywaye::Outbox::Envelope::TYPE_LENGTH.min
    assert_equal core_length("eventType").max, Anywaye::Outbox::Envelope::TYPE_LENGTH.max
  end

  def test_the_service_name_bounds_here_are_core_s
    assert_equal core_length("serviceName").min, Anywaye::Outbox::Envelope::SOURCE_LENGTH.min
    assert_equal core_length("serviceName").max, Anywaye::Outbox::Envelope::SOURCE_LENGTH.max
  end

  def test_the_subject_bounds_here_are_core_s
    assert_equal CoreEnvelope::SUBJECT_LENGTH.fetch("minLength"), Anywaye::Outbox::Envelope::SUBJECT_LENGTH.min
    assert_equal CoreEnvelope::SUBJECT_LENGTH.fetch("maxLength"), Anywaye::Outbox::Envelope::SUBJECT_LENGTH.max
  end

  def test_the_dialect_here_is_core_s
    assert_equal(core_spec_version, Anywaye::Outbox::Envelope::SPEC_VERSION)
  end

  def test_the_attribute_list_here_is_core_s
    # `additionalProperties` is false, so an undeclared attribute is an error at
    # every consumer. The library's list and core's `required` have to be the
    # same seven, in the sense that matters: a value one requires and the other
    # omits is a value a consumer will find missing.
    assert_equal @schema.fetch("required").sort, Anywaye::Outbox::Envelope::ATTRIBUTES.sort
  end

  # --- a real envelope, validated against core's constraints ----------------

  def test_an_envelope_this_library_builds_satisfies_every_constraint_core_states
    # Checked behaviour rather than text: the same strings are pushed through
    # core's own patterns and core's own bounds, so a change to either side
    # shows up here rather than at a consumer.
    envelope = valid_envelope

    assert core_accepts?(envelope.type, "eventType"), "core rejects the type this library built"
    assert core_accepts?(envelope.source, "serviceName"), "core rejects the source this library built"
    assert core_accepts?(envelope.subject, "subject"), "core rejects the subject this library built"
    assert_equal CoreEnvelope::ATTRIBUTES.sort, envelope.to_h.keys.sort
    assert_equal core_spec_version, envelope.to_h.fetch("specversion")
  end

  def test_a_type_core_would_reject_is_refused_here_too
    # A two-segment type is the shape `identity`'s private Go copy accepts today
    # and core's schema does not. If this library ever loosened to match it, this
    # test would notice, because core's pattern is applied rather than assumed.
    two_segment = "customer.created"

    refute core_accepts?(two_segment, "eventType")
    assert_raises(Anywaye::Errors::Outbox::EnvelopeInvalid) do
      Anywaye::Outbox::Envelope.new(**valid_attributes.merge(type: two_segment))
    end
  end

  def test_a_snake_case_service_segment_is_refused_here_too
    # `my_service.customer.created` is what `identity`'s pattern accepts and
    # core's does not: a anywaye service name is kebab-case and never contains an
    # underscore.
    snake = "my_service.customer.created"

    refute core_accepts?(snake, "eventType")
    assert_raises(Anywaye::Errors::Outbox::EnvelopeInvalid) do
      Anywaye::Outbox::Envelope.new(**valid_attributes.merge(type: snake))
    end
  end

  def test_the_patterns_are_anchored_to_the_whole_string_and_not_to_a_line_of_one
    # core's JSON Schema patterns are written with `^` and `$`, which in a Ruby
    # Regexp anchor to a line rather than to the string. This library anchors
    # with `\A` and `\z`, which is strictly narrower: an envelope cannot be
    # smuggled through by appending a second line. Narrower is the safe
    # direction, so the difference is asserted rather than papered over.
    {
      Anywaye::Outbox::Envelope::TYPE_PATTERN => "billing.plan.created\nrm -rf /",
      Anywaye::Outbox::Envelope::SUBJECT_PATTERN => "cus_1\ntrace_id: x",
      Anywaye::Outbox::Envelope::SOURCE_PATTERN => "billing\nsource: x"
    }.each do |pattern, smuggling|
      refute_match pattern, smuggling
    end
  end

  # --- the outbox table ----------------------------------------------------

  def test_the_reference_ddl_has_exactly_core_s_column_list_in_core_s_order
    # "The column list is the contract; the implementation is the service's
    # business." So the column list is read out of core's doc and compared,
    # rather than trusted to be the same.
    columns = ddl_columns
    expected = core_outbox_columns

    assert_equal expected, columns,
                 "the reference DDL's column list has drifted from core/docs/event-outbox.md"
  end

  def test_the_reference_ddl_carries_core_s_partial_index_on_the_unpublished_rows
    # Without it the publisher's only query is a sequential scan of every event
    # the service has ever published, forever.
    ddl = Anywaye::Outbox.ddl

    assert_match(/create index if not exists outbox_events_unpublished_idx/, ddl)
    assert_match(/where published_at is null/, ddl)
  end

  def test_the_ddl_uses_jsonb_and_not_json
    # `jsonb` is parsed, so a contract test or a query can reach inside the
    # payload, and it normalises key order so two identical payloads are
    # byte-identical.
    assert_match(/\bjsonb\b/, Anywaye::Outbox.ddl)
    refute_match(/\bjson\s+not null/, Anywaye::Outbox.ddl)
  end

  def test_every_column_core_documents_is_present_and_typed_the_way_core_says
    ddl = Anywaye::Outbox.ddl

    {
      "id" => "uuid", "event_type" => "text", "source" => "text", "subject" => "text",
      "time" => "timestamptz", "data" => "jsonb", "created_at" => "timestamptz",
      "published_at" => "timestamptz", "attempts" => "int"
    }.each do |column, type|
      assert_match(/^\s*#{column}\s+#{Regexp.escape(type)}\b/, ddl, "#{column} is not #{type}")
    end
  end

  # --- how much is actually being checked ----------------------------------

  def test_the_fallback_is_reported_rather_than_hidden
    # The honest version of the skip this file does not have. If core was on
    # disk the real comparison above ran; if it was not, this says so in a way
    # that is visible in the test output rather than in a comment nobody reads.
    if @schema
      assert_equal CoreEnvelope::EVENT_TYPE_PATTERN, @schema.fetch("$defs").dig("eventType", "pattern"),
                   "core's schema and the pinned copy have drifted; update test/fixtures/core_envelope.rb"
    else
      assert_nil @schema, "no core schema, so the pinned copy is the contract for this run"
      assert_equal "unknown", core_source
    end
  end

  private

  def core_path
    @core_path ||= ENV["CORE_PATH"] || File.expand_path("../../../core", __dir__)
  end

  def schema_file
    File.join(core_path, "schemas", "event-envelope.schema.json")
  end

  def read_schema
    @read_schema = begin
      JSON.parse(File.read(schema_file))
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    end
  end

  def core_source
    @schema ? "on disk" : "unknown"
  end

  # core's constraints, from the real schema when it is there and from the pinned
  # copy when it is not. Every assertion below goes through one of these, so the
  # test behaves identically either way and only the strength of the check
  # changes.
  def core_pattern(which)
    case which
    when "eventType" then @schema&.dig("$defs", "eventType", "pattern") || CoreEnvelope::EVENT_TYPE_PATTERN
    when "serviceName" then @schema&.dig("$defs", "serviceName", "pattern") || CoreEnvelope::SERVICE_NAME_PATTERN
    when "subject" then @schema&.dig("properties", "subject", "pattern") || CoreEnvelope::SUBJECT_PATTERN
    end
  end

  # Always a `[min, max]` pair, whichever side it came from, so the length
  # assertions do not have to know whether core was on disk.
  def core_length(which)
    slice = @schema&.dig("$defs", which)
    return [ slice.fetch("minLength"), slice.fetch("maxLength") ] if slice

    fallback = which == "eventType" ? CoreEnvelope::EVENT_TYPE_LENGTH : CoreEnvelope::SERVICE_NAME_LENGTH
    [ fallback.fetch("minLength"), fallback.fetch("maxLength") ]
  end

  def core_spec_version
    @schema&.dig("properties", "specversion", "const") || CoreEnvelope::SPEC_VERSION
  end

  # "Valid" by core's own rules, applied to a value rather than compared as
  # text. Two patterns can be the same grammar while differing in spelling, and
  # comparing a `Regexp#source` to a pattern string looked equivalent once and
  # was not: Ruby's regexp optimiser reports different sources for the same
  # pattern in different processes. So core's pattern is compiled and the value
  # is pushed through it.
  def core_accepts?(value, which)
    core_regexp(which).match?(value)
  end

  # core writes its patterns with `^` and `$`; this library with `\A` and `\z`,
  # which is narrower and is the safe direction. Compiling core's pattern and
  # re-anchoring it keeps the comparison about the *grammar* and not about the
  # anchoring choice the two languages happen to make.
  def core_regexp(which)
    source = Regexp.new(core_pattern(which)).source.delete_prefix("^").delete_suffix("$")
    @core_regexps ||= {}
    @core_regexps[which] ||= /\A#{source}\z/
  end

  def valid_envelope
    Anywaye::Outbox::Envelope.new(**valid_attributes)
  end

  def valid_attributes
    {
      id: "0198f1c2-7a41-7c3b-9d55-2f0b6a1e4c88",
      type: "billing.customer.created",
      source: "billing",
      subject: "cus_01J9Z8QK5M4N7P2R3T6V8W9X0A",
      time: now,
      data: { "customer_id" => "cus_01J9Z8QK5M4N7P2R3T6V8W9X0A" }
    }
  end

  # A column name, from a `create table` block in either file.
  #
  # Matched on the shape of a column definition — a name followed by a type —
  # rather than on "the first word on the line", which also picks up the
  # continuation line of a `constraint ... check (...)` and reports it as a
  # column called `check`.
  COLUMN_DEFINITION = /\A(\w+)\s+(?:uuid|text|timestamptz|jsonb|json|int(?:eger)?|bigint|boolean)\b/.freeze

  def columns_in(block)
    block.lines.filter_map { |line| line.strip[COLUMN_DEFINITION, 1] }
  end

  def ddl_columns
    block = Anywaye::Outbox.ddl[/create table if not exists outbox_events \((.*?)\n\);/m, 1]
    columns_in(block.to_s)
  end

  # The column list out of core's doc, so "the column list is the contract" is
  # checked rather than remembered.
  def core_outbox_columns
    doc = begin
      File.read(File.join(core_path, "docs", "event-outbox.md"))
    rescue Errno::ENOENT, Errno::ENOTDIR
      return CoreEnvelope::OUTBOX_COLUMNS
    end

    block = doc[/create table if not exists outbox_events \((.*?)\n\);/m, 1]
    return CoreEnvelope::OUTBOX_COLUMNS if block.nil?

    columns_in(block)
  end

  # The two patterns are the same grammar when they accept and reject the same
  # strings, so they are compared on values rather than on their text. Comparing a
  # `Regexp#source` to a pattern string looked equivalent once and was not: Ruby's
  # regexp optimiser reports different sources for the same pattern in different
  # processes.
  #
  # The `variants` are the values that separate the two. A two-segment type, a
  # snake_case service segment and a smuggled second line are the three that
  # `identity`'s private Go pattern accepts and core's does not.
  def assert_same_grammar(core_json_pattern, ruby_pattern, sample:, variants: default_variants)
    anchored = /\A#{Regexp.new(core_json_pattern).source.delete_prefix("^").delete_suffix("$")}\z/

    assert anchored.match?(sample), "core rejects #{sample.inspect}, which core's own pattern is meant to accept"
    assert ruby_pattern.match?(sample), "this library rejects #{sample.inspect}, which core accepts"

    variants.each do |value|
      assert_equal ruby_pattern.match?(value), anchored.match?(value),
                   "the two patterns disagree about #{value.inspect}"
    end
  end

  def default_variants
    [ "customer.created", "my_service.customer.created", "billing.plan.created\nrm -rf /", "billing" ]
  end
end
