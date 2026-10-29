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

      # The SIMPLE processor, and the reason is the same as it is in courier and
      # identity: the batch processor exports on a timer, so a test would have to
      # wait for somebody else's interval — which is a sleep, and a sleep is a
      # guess that is wrong on the machine where it matters. `SimpleSpanProcessor`
      # exports on span end, so a span is in the exporter by the time the response
      # has been returned.
      #
      # Its own doc warns against production use, and that warning is real: it
      # exports synchronously on the request thread. That is the deliberate trade
      # in a service whose request volume is a Stripe webhook and a handful of
      # reads — and the OTLP exporter has no retry queue and a short timeout, so a
      # collector that is down costs a failed export rather than a slow request.
      # A service that outgrew it would move to `BatchSpanProcessor` with a
      # bounded queue, and the switch is one line in this file.
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
