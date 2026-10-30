# frozen_string_literal: true

require "opentelemetry/sdk"

module TestSupport
  class TestSpanExporter < OpenTelemetry::SDK::Trace::Export::SpanExporter
    @spans = []
    @mutex = Mutex.new

    class << self
      def instance
        @instance ||= new
      end

      def finished_spans
        @mutex.synchronize { @spans.dup.freeze }
      end

      def clear!
        @mutex.synchronize { @spans.clear }
      end

      def record(span_datas)
        @mutex.synchronize { @spans.concat(span_datas.to_a) }
      end
    end

    def export(span_datas, timeout: nil)
      _ = timeout
      return OpenTelemetry::SDK::Trace::Export::FAILURE if @stopped

      self.class.record(span_datas)
      OpenTelemetry::SDK::Trace::Export::SUCCESS
    end
  end
end
