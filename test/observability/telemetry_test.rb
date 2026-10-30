require "test_helper"

class ObservabilityTelemetryTest < ActiveSupport::TestCase
  setup do
    TestSupport::TestSpanExporter.clear!
  end

  teardown do
    TestSupport::TestSpanExporter.clear!
  end


  test "BILLING_OTEL_ENDPOINT is the only variable, and it defaults to kit's collector" do
    assert_equal "BILLING_OTEL_ENDPOINT", Kit::Telemetry::ENDPOINT_VARIABLE,
                 "the endpoint variable is named differently from the fleet's contract, so a " \
                 "deployment that set <SERVICE>_OTEL_ENDPOINT for its other services would set " \
                 "one here that nothing reads"
    assert_equal "http://otel-collector:4318/v1/traces", Kit::Telemetry::DEFAULT_ENDPOINT
  end

  test "docker-compose.yml and the code agree on the default endpoint" do
    compose = File.read(Rails.root.join("docker-compose.yml"))

    assert_includes compose, "#{Kit::Telemetry::ENDPOINT_VARIABLE}: #{Kit::Telemetry::DEFAULT_ENDPOINT}",
                    "docker-compose.yml no longer states the endpoint it defaults to. A reader of " \
                    "this file cannot see where telemetry goes without reading the source, and the " \
                    "two are supposed to be one claim."
  end

  test "an unset endpoint falls back to the collector, and a set one is used verbatim" do
    unset = Kit::Exporter.endpoint(->(name) { "" })
    set = Kit::Exporter.endpoint(->(name) { "http://elsewhere:4318/v1/traces" })

    assert_equal Kit::Telemetry::DEFAULT_ENDPOINT, unset
    assert_equal "http://elsewhere:4318/v1/traces", set
  end

  test "the endpoint is the traces resource URL, which is the shape the exporter can use" do
    assert_equal "/v1/traces", URI(Kit::Telemetry::DEFAULT_ENDPOINT).path

    configured = Kit::Exporter.endpoint(->(name) { "http://elsewhere:4318/v1/traces" })
    assert_equal "/v1/traces", URI(configured).path,
                 "a base URL here is a request the exporter cannot build"
  end

  test "the exporter name is a closed vocabulary and anything else RAISES" do
    error = assert_raises(ArgumentError) do
      Kit::Exporter.build("something_from_the_environment", ->(name) { "" })
    end

    assert_includes error.message, "closed vocabulary",
                    "an unrecognised exporter name must not fall back to a default: an exporter " \
                    "that silently became `otlp` because of a typo is a service that stopped " \
                    "exporting into the suite and nobody would know why."
  end

  test "telemetry reports WHY it is off rather than being silently absent" do
    _ok, reason = Kit::Telemetry.enabled?("otlp", true)
    assert_equal "BILLING_OTEL_DISABLED is set", reason

    ok, no_reason = Kit::Telemetry.enabled?("otlp", false)
    assert ok
    assert_nil no_reason

    ok, missing = Kit::Telemetry.enabled?(nil, false)
    refute ok
    assert_equal "no exporter is configured", missing
  end

  test "a disabled install returns nil and installs nothing" do
    before = OpenTelemetry.tracer_provider

    provider = Kit::TracerInstaller.install!(exporter_name: "otlp", disabled: true, lookup: ->(_n) { "" })

    assert_nil provider
    assert_same before, OpenTelemetry.tracer_provider,
                "a disabled install still replaced the global provider, so `enabled?` is a claim " \
                "about the predicate rather than about the process"
  end

  test "the startup line names the service and the endpoint on the enabled path" do
    output = capture_log { Kit::Telemetry.log_startup(Rails.logger, "otlp", false, ->(name) { "" }) }

    assert_includes output, "service=billing"
    assert_includes output, Kit::Telemetry::DEFAULT_ENDPOINT
  end

  test "the startup line says why on the disabled path" do
    output = capture_log do
      Kit::Telemetry.log_startup(Rails.logger, "otlp", true, ->(name) { "" })
    end

    assert_includes output, "disabled"
    assert_includes output, "BILLING_OTEL_DISABLED"
  end

  private

  def capture_log
    io = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = previous
  end
end
