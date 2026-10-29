# frozen_string_literal: true

Rails.application.config.after_initialize do
  Kit::Telemetry.log_startup(
    Rails.logger,
    Rails.application.config.x.telemetry.exporter,
    ENV["BILLING_OTEL_DISABLED"].to_s.empty? == false,
    ->(name) { ENV.fetch(name, "") }
  )

  Kit::TracerInstaller.install!(
    exporter_name: Rails.application.config.x.telemetry.exporter,
    disabled: ENV["BILLING_OTEL_DISABLED"].to_s.empty? == false,
    lookup: ->(name) { ENV.fetch(name, "") }
  )
end
