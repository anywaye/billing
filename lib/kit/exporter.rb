# frozen_string_literal: true

require_relative "telemetry"

module Kit
  # Which exporter billing installs, and the one place that decision is made.
  #
  # A CLOSED vocabulary rather than a constant name read from the environment. The
  # obvious alternative — `Object.const_get(ENV.fetch("BILLING_OTEL_EXPORTER"))` —
  # is an arbitrary constant lookup driven by a string anyone who can set an
  # environment variable can write, which in a service that seals customer money
  # is not a seam worth having. So the exporter is named by Rails configuration
  # (`config.x.telemetry.exporter`, one line per environment file), the name is
  # matched against a `case`, and anything unrecognised RAISES rather than
  # defaulting: an exporter that silently became `otlp` because of a typo is a
  # service that stopped exporting into the suite and nobody would know why.
  module Exporter
    OTLP = "otlp"
    TEST = "test"

    module_function

    # The exporter to install. `lookup` is the environment seam, for the reason
    # every seam in this repository takes one.
    def build(name, lookup)
      case name.to_s
      when OTLP
        OpenTelemetry::Exporter::OTLP::Exporter.new(endpoint: endpoint(lookup))
      when TEST
        require Rails.root.join("test/support/test_span_exporter").to_s
        TestSupport::TestSpanExporter.instance
      else
        raise ArgumentError,
              "unknown telemetry exporter #{name.inspect}; the closed vocabulary is " \
              "#{[ OTLP, TEST ].inspect}"
      end
    end

    # The OTLP endpoint, defaulted to the collector that ships with kit's stack.
    def endpoint(lookup)
      value = lookup.call(Kit::Telemetry::ENDPOINT_VARIABLE).to_s
      if value.empty?
        value = lookup.call("OTEL_EXPORTER_OTLP_ENDPOINT").to_s
        # The OTLP/HTTP exporter uses the endpoint verbatim (prepare_endpoint
        # only joins v1/traces onto the gem's own default), so a base address
        # must gain the signal path here or every export 404s.
        value = "#{value}/v1/traces" unless value.empty? || value.end_with?("/v1/traces")
      end
      value.empty? ? Kit::Telemetry::DEFAULT_ENDPOINT : value
    end
  end
end
