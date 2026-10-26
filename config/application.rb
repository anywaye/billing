require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# OpenTelemetry, required AFTER `Bundler.require` and before the application class
# body, and the order is load-bearing in both directions.
#
# AFTER, because these files name `OpenTelemetry::*` constants at load time —
# `RequestTelemetry::RACK_ENV_GETTER` resolves one — and the gems that define them
# arrive with `Bundler.require`.
#
# BEFORE, because the middleware stack is assembled in the class body below and a
# class constant referenced from this file cannot come from an autoload path: Rails
# refuses to autoload during initialization, and would rather fail at boot than
# build a stack whose telemetry silently does not exist.
#
# They live in `lib/` and are ignored by the autoloader (`kit`, `middleware` below)
# precisely so that this `require` and Zeitwerk do not both own the same file.
require_relative "../lib/kit/telemetry"
require_relative "../lib/kit/exporter"
require_relative "../lib/kit/tracer_installer"
require_relative "../lib/middleware/request_telemetry"

module Billing
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    #
    # `kit` and `middleware` are this repository's, and both are ignored because
    # `config/application.rb` requires them explicitly above. They are loaded
    # during boot rather than autoloaded because the middleware stack is built
    # here, and a reloaded telemetry module would mean a middleware holding a
    # tracer from a previous boot.
    config.autoload_lib(ignore: %w[assets tasks kit middleware])

    # OPENTELEMETRY, and it is ON BY DEFAULT in every environment.
    #
    # A developer running `bin/rails server` exports into the collector that ships
    # with kit's stack, and a deployer gets traces without assembling anything.
    # Gating this to production would make the default a no-op everywhere it is
    # actually used, which is backwards — and it would make this repository's own
    # redaction tests assert nothing, because a suite with no exporter exports
    # nothing and every "the canary is absent" assertion would pass having proved
    # nothing at all.
    #
    # `config.x.telemetry.exporter` is the one thing the installer branches on, and
    # its value is a CLOSED vocabulary read from the environment file that set it —
    # never a constant name from the environment. See `Kit::Exporter`.
    config.x.telemetry.exporter = "otlp"
    config.middleware.insert_before(0, RequestTelemetry)

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    # Send every response Rails raises into the application's own routes
    # (config/routes.rb maps /404, /422, /500 and /503 to ErrorsController)
    # instead of Rails' static HTML error pages. An API whose unknown paths
    # answer with an HTML document has one response a client cannot parse, and
    # core's openapi-conventions.md says every non-2xx is
    # `application/problem+json`. The probes are unaffected: they are rendered
    # by a controller, not raised.
    config.exceptions_app = routes
  end
end
