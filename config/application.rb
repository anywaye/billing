require_relative "boot"

require "rails/all"

Bundler.require(*Rails.groups)

require_relative "../lib/kit/telemetry"
require_relative "../lib/kit/exporter"
require_relative "../lib/kit/tracer_installer"
require_relative "../lib/middleware/request_telemetry"

module Billing
  class Application < Rails::Application
    config.load_defaults 8.1

    config.autoload_lib(ignore: %w[assets tasks kit middleware])

    config.x.telemetry.exporter = "otlp"
    config.middleware.insert_before(0, RequestTelemetry)


    config.api_only = true

    config.exceptions_app = routes
  end
end
