require "test_helper"

class ObservabilityAllowlistTest < ActiveSupport::TestCase
  FORBIDDEN_WORDS = %w[
    prompt message content text body header query params parameter payload
    email subject recipient recipient_id customer user account tenant owner
    secret token credential authorization cookie api_key signature
    price amount currency minor_units invoice
    detail exception stacktrace sql
  ].freeze

  test "no allowed name contains a word that names content" do
    offenders = Kit::Telemetry::ALLOWED_SPAN_ATTRIBUTES.select do |name|
      lowered = name.downcase
      FORBIDDEN_WORDS.any? { |word| lowered.include?(word) }
    end

    assert_empty offenders,
                 "the span-attribute allowlist carries names that could hold content: #{offenders.inspect}.\n\n" \
                 "This list is the redaction boundary. A name that names content is a name " \
                 "somebody will fill with the thing it names, and nothing downstream can " \
                 "strip it: `Kit::Telemetry.record/2` is the only recorder, so a name that " \
                 "gets in here gets exported."
  end

  test "the allowlist is frozen" do
    assert_predicate Kit::Telemetry::ALLOWED_SPAN_ATTRIBUTES, :frozen?,
                     "a mutable allowlist is a list something can add to at runtime, in a " \
                     "process that has already decided what it may export"
  end

  test "every allowed name is a semantic convention this service can actually set" do
    assert_equal %w[http.request.method http.response.status_code http.route error.type].sort,
                 Kit::Telemetry::ALLOWED_SPAN_ATTRIBUTES.sort
  end

  test "a name that is not on the list is DROPPED, not recorded" do
    span = FakeSpan.new

    Kit::Telemetry.record(span, { "customer.email" => "someone@example.com" })

    assert_empty span.attributes,
                 "record/2 recorded an attribute that is not on the allowlist. That function " \
                 "is the boundary; a name it accepts is a name that leaves the process."
  end

  test "a name on the list IS recorded" do
    span = FakeSpan.new

    Kit::Telemetry.record(span, { "http.route" => "/v1/customers/:id" })

    assert_equal({ "http.route" => "/v1/customers/:id" }, span.attributes)
  end

  test "a symbol key is recorded when its NAME is allowed, and dropped when it is not" do
    span = FakeSpan.new

    Kit::Telemetry.record(span, { "http.request.method": "GET", customer_email: "someone@example.com" })

    assert_equal({ "http.request.method" => "GET" }, span.attributes)
  end

  test "a nil value is dropped even when the name is allowed" do
    span = FakeSpan.new

    Kit::Telemetry.record(span, { "error.type" => nil })

    assert_empty span.attributes
  end

  test "a nil span and nil attributes are both no-ops" do
    assert_nil Kit::Telemetry.record(nil, { "http.route" => "/v1/plans" })

    span = FakeSpan.new
    assert_same span, Kit::Telemetry.record(span, nil)
    assert_empty span.attributes
  end

  test "a value that is a whole customer record is refused by the NAME, not by its shape" do
    span = FakeSpan.new
    customer = Struct.new(:email, :processor_customer_id, keyword_init: true).new(
      email: "someone@example.com", processor_customer_id: "cus_123"
    )

    Kit::Telemetry.record(span, { "http.route" => "/v1/customers", "billing.customer" => customer })

    assert_equal({ "http.route" => "/v1/customers" }, span.attributes)
  end

  test "error.type is a CLOSED vocabulary, and a value outside it is not recorded" do
    span = FakeSpan.new

    Kit::Telemetry.record(span, { "error.type" => "PG::ConnectionBad" })

    assert_empty span.attributes,
                 "an exception class name became a span attribute. That is unbounded " \
                 "cardinality from a library's own naming, and it is the reason " \
                 "Kit::Telemetry::ERROR_TYPES exists."
  end

  test "every value Kit::Telemetry can produce for error.type is on the closed list" do
    produced = [
      Kit::Telemetry.error_type(RuntimeError.new("boom"), :unhandled),
      Kit::Telemetry.error_type(StandardError.new, :routing),
      Kit::Telemetry.error_type(StandardError.new, :middleware)
    ].compact

    assert_equal Kit::Telemetry::ERROR_TYPES.sort, produced.sort,
                 "error_type/2 produced a value that is not in the closed vocabulary. Either " \
                 "the vocabulary or the function has drifted, and a label that is not in the " \
                 "closed list is one more series per exception class."
  end

  test "error_type returns nil for a value it does not recognise" do
    assert_nil Kit::Telemetry.error_type(nil, :something_new)
    assert_nil Kit::Telemetry.error_type("not even an exception", :unhandled)
  end

  class FakeSpan
    attr_reader :attributes

    def initialize
      @attributes = {}
    end

    def set_attribute(name, value)
      @attributes[name] = value
    end
  end
end
