# frozen_string_literal: true

require_relative "telemetry"
require_relative "exporter"

module Kit
  # Installs the tracer provider, or says why it did not.
  #
  # `OpenTelemetry.tracer_provider` is a global, and a global installed twice in
  # one process is a suite asserting about whichever one won. So `install!` returns
  # the provider it built and the caller keeps it.
  module TracerInstaller
    module_function

    # Build the provider, install it globally, and return it. Nil when telemetry
    # is switched off, which is a supported state and not an error.
    def install!(exporter_name:, disabled:, lookup:)
      ok, _reason = Kit::Telemetry.enabled?(exporter_name, disabled)
      return nil unless ok

      exporter = Kit::Exporter.build(exporter_name, lookup)

      processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)

      provider = OpenTelemetry::SDK::Trace::TracerProvider.new(
        resource: Kit::Telemetry.resource(lookup)
      )
      provider.add_span_processor(processor)

      OpenTelemetry.tracer_provider = provider

      OpenTelemetry.propagation = OpenTelemetry::Trace::Propagation::TraceContext.text_map_propagator

      provider
    end
  end
end
