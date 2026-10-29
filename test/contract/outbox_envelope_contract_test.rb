require "test_helper"

class OutboxEnvelopeContractTest < ActiveSupport::TestCase
  ENVELOPE_SCHEMA = "schemas/event-envelope.schema.json"
  MANIFEST = "anywaye.yml"

  PENDING_CORE_CATALOG_ROWS = %w[billing.plan.updated].freeze

  PENDING_PAYLOAD_ALIGNMENT = {
    "billing.plan.created" => {
      unexpected: %w[entitlements]
    },
    "billing.plan.updated" => {
      unexpected: %w[entitlements]
    },
    "billing.payment.succeeded" => {
      unexpected: %w[anywaye_customer_id]
    },
    "billing.payment.failed" => {
      unexpected: %w[anywaye_customer_id]
    },
    "billing.subscription.started" => {
      missing: %w[customer_id kind processor processor_event_id],
      unexpected: %w[account_id currency plan_id started_at]
    },
    "billing.subscription.updated" => {
      missing: %w[customer_id kind],
      unexpected: %w[account_id currency plan_id processor_subscription_id]
    },
    "billing.subscription.canceled" => {
      missing: %w[customer_id kind],
      unexpected: %w[account_id currency plan_id processor_subscription_id]
    }
  }.freeze

  PENDING_ID_PATTERNS = {}.freeze

  NO_PAYLOAD_SCHEMA_YET = [].freeze

  UNDERSTOOD_KEYWORDS = %w[
    $id $schema $comment title description
    type enum const format pattern
    minLength maxLength minimum maximum
    properties required additionalProperties oneOf
  ].freeze

  JSON_TYPES = %w[string number integer boolean object array null].freeze

  UNDERSTOOD_FORMATS = {
    "uuid" => ->(value) { Identifiers::UUID.match?(value) },
    "date-time" => ->(value) { value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/) },
    "email" => ->(value) { URI::MailTo::EMAIL_REGEXP.match?(value) }
  }.freeze

  ONE_OF_BRANCH_KEYWORDS = %w[$comment title description required].freeze

  WEBHOOK_FIXTURES = %w[
    customer.subscription.created
    customer.subscription.updated
    customer.subscription.deleted
    invoice.paid
    invoice.payment_failed
    checkout.session.completed.payment
  ].freeze

  setup do
    skip("core is not on disk; set CORE_PATH to #{default_core_path}") unless schema
    travel_to(frozen_now)
  end

  test "every event billing emits satisfies core's envelope schema" do
    envelopes.each do |envelope|
      assert_valid_envelope(envelope)
    end
  end

  test "the event type pattern this service validates against is core's" do
    assert_same_grammar schema.fetch("$defs").dig("eventType", "pattern"), OutboxEvent::TYPE_PATTERN
  end

  test "the subject pattern this service validates against is core's" do
    assert_same_grammar schema.fetch("properties").dig("subject", "pattern"), OutboxEvent::SUBJECT_PATTERN
  end

  test "an event type is anchored to the whole string, not to a line of one" do
    assert_not OutboxEvent::TYPE_PATTERN.match?("billing.plan.created\nrm -rf /")
    assert_not OutboxEvent::SUBJECT_PATTERN.match?("cus_1\ntrace_id: x")
  end

  test "the source is the service name, which is what core requires of it" do
    assert_equal manifest.fetch("name"), "billing"
    envelopes.each { |envelope| assert_equal "billing", envelope.fetch("source") }
  end

  test "every type in the manifest is a type this service can emit" do
    assert_equal manifest.fetch("exposes").fetch("events").sort, OutboxEvent::TYPES.sort
  end

  test "every type this service emits has a catalog row in core" do
    catalog = core_catalog

    skip("core's catalog could not be read") if catalog.nil?

    undeclared = OutboxEvent::TYPES - catalog

    assert_empty undeclared - PENDING_CORE_CATALOG_ROWS,
      "core's catalog has no row for these, and nothing is tracking that: #{undeclared.inspect}"
  end

  test "every event payload matches core's payload schema, where one exists" do
    assert_equal PENDING_PAYLOAD_ALIGNMENT, payload_mismatches,
      "the payloads that do not match core's schemas have changed: fix them, or record the new gap in PENDING_PAYLOAD_ALIGNMENT and in anywaye.yml"
  end

  test "every keyword core's payload schemas use is one this validator understands" do
    unread = core_constraint_keywords - UNDERSTOOD_KEYWORDS

    assert_empty unread,
      "core's payload schemas now use #{unread.inspect}, which this validator does not model: " \
      "teach it, or the check silently stops covering what core declared"
  end

  test "the payload validator refuses a type it does not understand, rather than accepting it" do
    assert_raises(RuntimeError) { value_is_type?("date", "2026-09-30") }
    assert_raises(RuntimeError) { value_is_type?("strng", "x") }
    assert_raises(RuntimeError) { value_is_type?({ "type" => "string" }, "x") }
  end

  test "the payload validator refuses a keyword it does not understand, rather than skipping it" do
    assert_raises(RuntimeError) { violations({ "patternProperties" => {} }, {}, "slug") }
    assert_raises(RuntimeError) { violations({ "format" => "hostname" }, "anywaye.com", "site") }
  end

  test "a $comment is ignored as metadata, and changes no verdict in either direction" do
    schema_for = lambda do |where, note|
      property = { "type" => "string" }
      root = { "type" => "object", "properties" => { "id" => property }, "required" => %w[id] }
      case where
      when :root then root.merge("$comment" => note)
      when :property then root.merge("properties" => { "id" => property.merge("$comment" => note) })
      end
    end

    %i[root property].each do |where|
      label = "at the #{where} level"

      assert_empty violations(schema_for.(where, nil), { "id" => "x" }, "data"),
        "a valid payload is valid #{label} with no comment present"
      assert_empty violations(schema_for.(where, "id MUST be an integer"), { "id" => "x" }, "data"),
        "a comment demanding a stricter payload did not change a passing verdict #{label}"
      assert_equal 1, violations(schema_for.(where, nil), { "id" => 7 }, "data").length,
        "a breaching payload breaches #{label} with no comment present"
      assert_equal 1, violations(schema_for.(where, "id is fine"), { "id" => 7 }, "data").length,
        "a comment excusing a breaching payload did not change a failing verdict #{label}"
      assert_empty violations(schema_for.(where, 42), { "id" => "x" }, "data"),
        "a non-string comment is still ignored rather than refused #{label}"
      assert_equal 1, violations(schema_for.(where, { "id" => "string" }), { "id" => 7 }, "data").length,
        "a comment carrying a schema is still ignored rather than honoured #{label}"
    end
  end

  PENDING_ID_PATTERN_TEST = "the id patterns core declares are met by every value we emit, and every one they miss is recorded"

  PATTERN_CORPUS = [
    "pro-monthly",
    "USD",
    "pro",
    "pro_monthly",
    "Pro-Monthly",
    "-pro-monthly",
    "pro-monthly-",
    "pro--monthly",
    "pro.monthly",
    "pro/monthly",
    "pro monthly",
    "",
    "usd",
    "US",
    "USDD",
    "US1",
    "123",
    "U$D"
  ].freeze

  test PENDING_ID_PATTERN_TEST do
    assert_equal id_pattern_gaps, PENDING_ID_PATTERNS,
      "the id-format gaps have changed: a value that now meets core's pattern means the entry goes, " \
      "and a pattern core declares that a value misses means a new entry is owed"
  end

  test "this service's slug pattern and core's accept exactly the same strings" do
    assert_same_grammar declared_pattern("billing.plan.created", "slug"), Plan::SLUG_PATTERN, PATTERN_CORPUS
  end

  test "this service's currency pattern and core's accept exactly the same strings" do
    assert_same_grammar declared_pattern("billing.plan.created", "price.currency"), Billing::Money::CURRENCY_FORMAT, PATTERN_CORPUS
  end

  test "core's patterns are anchored to a line, where this service reads them as anchored to the whole string" do
    patterns = core_patterns

    assert_not_empty patterns, "core declares no pattern on any payload this build publishes: re-read the schemas"

    patterns.each do |event_type, field, pattern, value|
      assert pattern.start_with?("^"),
        "core's pattern for #{event_type}.#{field} is no longer anchored with ^: re-read the schema"

      forged = "#{value}\nforged"

      assert Regexp.new(pattern).match?(forged),
        "core's pattern for #{event_type}.#{field} no longer accepts a second line, so the comparison this test draws is not the one it names"
      assert_not whole_string(pattern).match?(forged),
        "the whole-string reading of core's pattern for #{event_type}.#{field} accepts a second line, which is the direction this service must never take"
    end
  end

  test "the corpus would notice a pattern that had changed" do
    changed = Regexp.new("^[a-z0-9]{1,20}$")

    disagreements = PATTERN_CORPUS.reject { |candidate| changed.match?(candidate) == Plan::SLUG_PATTERN.match?(candidate) }

    assert_not_empty disagreements, "the corpus cannot tell two different patterns apart"
  end

  test "the set of events with an id-pattern gap has changed" do
    assert_equal PENDING_ID_PATTERNS.keys.sort, id_pattern_gaps.keys.sort,
      "the set of events checked for an id-format gap has changed: update PENDING_ID_PATTERNS and the reason in anywaye.yml"
  end

  test "the set of events with no payload schema in core has changed" do
    unspecified = OutboxEvent::TYPES.reject { |event_type| payload_schema_for(event_type) }

    assert_equal NO_PAYLOAD_SCHEMA_YET.sort, unspecified.sort,
      "the set of events with no payload schema in core has changed: drop the entries this service no longer owes one for, and record the ones it still does"
  end

  test "the events under test are every type this service publishes" do
    assert_equal OutboxEvent::TYPES.sort, envelopes.map { |envelope| envelope.fetch("type") }.uniq.sort
  end


  private

    def envelopes
      @envelopes ||= emit_one_event_of_every_type
    end

    def emit_one_event_of_every_type
      Customer.create!(
        owner_type: "Account",
        owner_id: "11111111-1111-4111-8111-111111111111",
        processor: "stripe",
        processor_customer_id: StripeSubscriptionFixtures::PROCESSOR_CUSTOMER_ID,
        email: "billing@example.com"
      )
      plan = Plan.create!(
        name: "Pro monthly",
        slug: "pro-monthly",
        price: Billing::Money.new(1900, "USD"),
        interval: "month",
        processor_price_id: StripeSubscriptionFixtures::PROCESSOR_PRICE_ID
      )
      plan.update!(active: false)

      WEBHOOK_FIXTURES.each { |fixture| ingest(fixture) }

      OutboxEvent.order(:created_at, :id).map(&:to_envelope)
    end

    def ingest(fixture)
      body = JSON.parse(stripe_fixture(fixture))

      Webhooks::Ingestion.new(processor: :stripe, event_id: body["id"], type: body["type"], payload: body).call
    end

    def payloads_for(event_type)
      @payloads_for ||= {}
      @payloads_for[event_type] ||= envelopes.select { |envelope| envelope.fetch("type") == event_type }.map { |envelope| envelope.fetch("data") }
    end

    def payload_mismatches
      OutboxEvent::TYPES.each_with_object({}) do |event_type, mismatches|
        schema = payload_schema_for(event_type)
        next if schema.nil?

        difference = payloads_for(event_type)
          .map { |data| disagreements(schema, data) }
          .reduce({}) { |merged, one| merge_disagreements(merged, one) }
          .reject { |_reason, entries| entries.empty? }

        mismatches[event_type] = difference if difference.any?
      end
    end

    def disagreements(schema, data)
      {
        missing: required_paths(schema, data).sort,
        unexpected: undeclared_paths(schema, data).sort,
        invalid: invalid_paths(schema, data).sort
      }
    end

    def merge_disagreements(left, right)
      left.merge(right) { |_reason, here, there| (here + there).uniq.sort }
    end

    def required_paths(schema, data, prefix = nil)
      return [] unless data.is_a?(Hash)

      here = (schema["required"] || []).reject { |name| data.key?(name) }.map { |name| dotted(prefix, name) }
      there = (schema["properties"] || {}).flat_map { |name, constraint| required_paths(constraint, data[name], dotted(prefix, name)) }

      here + there
    end

    def undeclared_paths(schema, data, prefix = nil)
      return [] unless data.is_a?(Hash)
      return [] unless schema["additionalProperties"] == false

      (data.keys - (schema["properties"] || {}).keys).map { |name| dotted(prefix, name) }
    end

    def invalid_paths(schema, value, prefix = nil)
      return [] unless value.is_a?(Hash)

      (schema["properties"] || {}).filter_map { |name, constraint|
        violations(constraint, value[name], dotted(prefix, name)) if value.key?(name)
      }.flatten
    end

    def dotted(prefix, name)
      [ prefix, name ].compact.join(".")
    end

    def violations(constraint, value, field)
      refuse_unknown_keywords(constraint, field)

      scalar_violations(constraint, value, field) +
        one_of_violations(constraint, value, field) +
        nested_shape_sentences(constraint, value, field) +
        invalid_paths(constraint, value, field)
    end

    def refuse_unknown_keywords(constraint, field, understood = UNDERSTOOD_KEYWORDS)
      unreadable = constraint.keys - understood

      raise "this test does not understand #{unreadable.inspect} on #{field}" if unreadable.any?
    end

    def nested_shape_sentences(constraint, value, field)
      return [] unless value.is_a?(Hash)

      absent = (constraint["required"] || []).reject { |name| value.key?(name) }
        .map { |name| "#{field}.#{name} is required by core and is not in the payload" }
      extra = constraint["additionalProperties"] == false ? (value.keys - (constraint["properties"] || {}).keys)
        .map { |name| "#{field}.#{name} is not a property core declares" } : []

      absent + extra
    end

    def scalar_violations(constraint, value, field)
      [
        type_violation(constraint, value, field),
        enum_violation(constraint, value, field),
        const_violation(constraint, value, field),
        pattern_violation(constraint, value, field),
        bound_violations(constraint, value, field),
        format_violation(constraint, value, field)
      ].flatten.compact
    end

    def type_violation(constraint, value, field)
      return unless constraint.key?("type")

      declared = constraint.fetch("type")
      types = declared.is_a?(Array) ? declared : [ declared ]
      unreadable = types - JSON_TYPES

      raise "this test does not understand type #{unreadable.inspect} on #{field}" if unreadable.any?
      raise "this test does not understand type #{declared.inspect} on #{field}" unless types.size == (declared.is_a?(Array) ? declared.size : 1)
      return if types.any? { |type| value_is_type?(type, value) }

      "#{field} is #{json_type_of(value)}, core says #{declared.inspect}"
    end

    def enum_violation(constraint, value, field)
      return unless constraint.key?("enum")
      return if constraint.fetch("enum").include?(value)

      "#{field} is #{value.inspect}, which is not one of #{constraint.fetch("enum").inspect}"
    end

    def const_violation(constraint, value, field)
      return unless constraint.key?("const")
      return if constraint.fetch("const") == value

      "#{field} is #{value.inspect}, core says it is #{constraint.fetch("const").inspect}"
    end

    def pattern_violation(constraint, value, field)
      return unless constraint.key?("pattern")
      return if value.is_a?(String) && whole_string(constraint.fetch("pattern")).match?(value)

      "#{field} is #{value.inspect}, core's pattern #{constraint.fetch("pattern").inspect} does not accept it"
    end

    def bound_violations(constraint, value, field)
      [
        length_violation(constraint, value, field, "minLength", :>=),
        length_violation(constraint, value, field, "maxLength", :<=),
        numeric_violation(constraint, value, field, "minimum", :>=),
        numeric_violation(constraint, value, field, "maximum", :<=)
      ].compact
    end

    def length_violation(constraint, value, field, keyword, direction)
      return unless constraint.key?(keyword) && value.is_a?(String)

      length = value.length
      return if direction == :>= ? length >= constraint.fetch(keyword) : length <= constraint.fetch(keyword)

      "#{field} is #{length} characters long, core says #{keyword} #{constraint.fetch(keyword)}"
    end

    def numeric_violation(constraint, value, field, keyword, direction)
      return unless constraint.key?(keyword) && value.is_a?(Numeric)

      return if direction == :>= ? value >= constraint.fetch(keyword) : value <= constraint.fetch(keyword)

      "#{field} is #{value.inspect}, core says #{keyword} #{constraint.fetch(keyword)}"
    end

    def format_violation(constraint, value, field)
      return unless constraint.key?("format")
      return unless value.is_a?(String)

      format = constraint.fetch("format")
      check = UNDERSTOOD_FORMATS[format]

      raise "this test does not understand format #{format.inspect} on #{field}" if check.nil?
      return if check.call(value)

      "#{field} is #{value.inspect}, which is not a #{format}"
    end

    def one_of_violations(constraint, value, field)
      return [] unless constraint.key?("oneOf")

      satisfied = constraint.fetch("oneOf").count { |branch|
        refuse_unknown_keywords(branch, field, ONE_OF_BRANCH_KEYWORDS)
        value.is_a?(Hash) && (branch["required"] || []).all? { |name| value.key?(name) }
      }

      return [] if satisfied == 1

      [ "#{field} satisfies #{satisfied} of core's #{constraint.fetch("oneOf").size} declared shapes, and exactly one of them" ]
    end

    def value_is_type?(declared, value)
      case declared
      when "string" then value.is_a?(String)
      when "integer" then value.is_a?(Integer)
      when "number" then value.is_a?(Integer) || value.is_a?(Float)
      when "boolean" then value.equal?(true) || value.equal?(false)
      when "object" then value.is_a?(Hash)
      when "array" then value.is_a?(Array)
      when "null" then value.nil?
      else raise "this test does not understand type #{declared.inspect}"
      end
    end

    def json_type_of(value)
      case value
      when nil then "null"
      when true, false then "boolean"
      when Integer then "integer"
      when String then "string"
      when Hash then "object"
      when Array then "array"
      else value.class.name
      end
    end


    def core_path
      @core_path ||= core_location.path_for
    end

    def default_core_path
      @default_core_path ||= core_location.searched.first
    end

    def core_location
      TestSupport::CoreLocation
    end

    def schema
      return @schema if defined?(@schema)

      @schema = begin
        JSON.parse(File.read(File.join(core_path, ENVELOPE_SCHEMA)))
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end
    end

    def manifest
      @manifest ||= YAML.safe_load_file(Rails.root.join(MANIFEST), permitted_classes: [], aliases: false).transform_keys(&:to_s)
    end

    def payload_schema_for(event_type)
      @payload_schemas ||= {}
      @payload_schemas.fetch(event_type) do
        path = File.join(core_path, "schemas", "events", event_type.tr(".", "/") + ".schema.json")

        @payload_schemas[event_type] = begin
          JSON.parse(File.read(path))
        rescue Errno::ENOENT, Errno::ENOTDIR
          nil
        end
      end
    end

    def core_patterns
      OutboxEvent::TYPES.flat_map { |event_type|
        schema = payload_schema_for(event_type)
        next [] if schema.nil?

        payloads_for(event_type).flat_map { |data| patterns_in(schema, data, event_type) }
      }
    end

    def patterns_in(constraint, value, event_type, prefix = nil, found = [])
      return found unless constraint["properties"].is_a?(Hash)

      constraint["properties"].each do |name, child|
        here = value.is_a?(Hash) ? value[name] : nil

        found << [ event_type, dotted(prefix, name), child.fetch("pattern"), here ] if here.is_a?(String) && child.key?("pattern")

        patterns_in(child, here, event_type, dotted(prefix, name), found)
      end

      found
    end

    def id_pattern_gaps
      core_patterns.each_with_object({}) do |(event_type, field, pattern, value), gaps|
        next if value.is_a?(String) && whole_string(pattern).match?(value)

        ((gaps[event_type] ||= {})[field] = whole_string(pattern))
      end
    end

    def declared_pattern(event_type, field)
      *parents, name = field.split(".")
      node = parents.reduce(payload_schema_for(event_type)) { |schema, part| schema.fetch("properties").fetch(part) }

      node.fetch("properties").fetch(name).fetch("pattern")
    rescue KeyError
      raise "core declares no pattern for #{event_type}.#{field}: re-read the schema before comparing grammars"
    end

    def whole_string(pattern)
      Regexp.new("\\A(?:#{pattern})\\z")
    end

    def core_constraint_keywords
      OutboxEvent::TYPES.filter_map { |event_type| payload_schema_for(event_type) }
        .flat_map { |schema| keywords_in(schema) }
        .uniq
    end

    def keywords_in(node, found = [])
      case node
      when Hash
        node.each do |keyword, value|
          found << keyword

          case keyword
          when "properties" then value.each_value { |child| keywords_in(child, found) }
          when "oneOf" then value.each { |branch| keywords_in(branch, found) }
          end
        end
      when Array then node.each { |child| keywords_in(child, found) }
      end

      found
    end

    def core_catalog
      return @core_catalog if defined?(@core_catalog)

      text = begin
        File.read(File.join(core_path, "docs", "event-naming.md"))
      rescue Errno::ENOENT, Errno::ENOTDIR
        return @core_catalog = nil
      end

      section = text[/^## Catalog.*?(?=^## )/m]
      billing = section[/^### billing.*?(?=^### |\z)/m]

      @core_catalog = billing.to_s.scan(/^\|\s*`([a-z][a-z0-9_.]+)`\s*\|/).flatten
    end


    GRAMMAR_CORPUS = [
      "billing.customer.created",
      "billing.payment.failed",
      "billing.payment.succeeded",
      "billing.plan.created",
      "billing.plan.updated",
      "billing.subscription.canceled",
      "billing.subscription.started",
      "billing.subscription.updated",
      "customer.created",
      "11111111-1111-4111-8111-111111111111",
      "usr_01J9Z8QK5M4N7P2R3T6V8W9X0A",
      "sub_1PZQaBcDeFgHiJkLmNoPqR1",
      "identity.api_key.created",
      "billing",
      "customer",
      "",
      "Billing.customer.created",
      "billing.Customer.created",
      "1billing.customer.created",
      "billing..created",
      "billing.customer.",
      ".billing.customer",
      "billing.customer.created.",
      "billing.customer.created.extra",
      "billing-customer.created",
      "billing_customer.created",
      "billing.customer.created ",
      " billing.customer.created",
      "user@example.com",
      "cus_1",
      "-cus_1",
      "_cus_1",
      "cus 1",
      "cus/1",
      "cus:1",
      "cus@1"
    ].freeze

    def assert_same_grammar(core_pattern, ours, corpus = GRAMMAR_CORPUS)
      theirs = Regexp.new(core_pattern)

      disagreements = corpus.reject { |candidate| theirs.match?(candidate) == ours.match?(candidate) }

      assert_empty disagreements, "core and this service disagree about: #{disagreements.inspect}"
    end

    def assert_valid_envelope(envelope)
      properties = schema.fetch("properties")

      assert_empty schema.fetch("required") - envelope.keys, "envelope is missing a required attribute"
      assert_empty envelope.keys - properties.keys, "additionalProperties is false in core"

      assert_equal properties.dig("specversion", "const"), envelope.fetch("specversion")
      assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, envelope.fetch("id"))
      assert_within(resolve(properties.fetch("type")), envelope.fetch("type"))
      assert_within(resolve(properties.fetch("source")), envelope.fetch("source"))
      assert_within(properties.fetch("subject"), envelope.fetch("subject"))
      assert_kind_of Hash, envelope.fetch("data")
      assert_time_is_rfc3339(envelope.fetch("time"))
    end

    def resolve(constraint)
      return constraint unless constraint.key?("$ref")

      constraint.fetch("$ref").delete_prefix("#/").split("/").reduce(schema) { |node, key| node.fetch(key) }
    end

    def assert_within(constraint, value)
      assert_kind_of String, value
      assert_operator value.length, :>=, constraint.fetch("minLength")
      assert_operator value.length, :<=, constraint.fetch("maxLength")
      assert_match(/#{constraint.fetch("pattern")}/, value, "#{value.inspect} must match core's pattern")
    end

    def assert_time_is_rfc3339(value)
      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, value)
    end
end
