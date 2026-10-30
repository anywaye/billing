# frozen_string_literal: true

module Kit
  # OpenTelemetry for billing, and the boundary that keeps it empty of content.
  #
  # WHAT THIS MODULE IS. Three things and no more:
  #
  #   * the CONTRACT with a collector — one endpoint variable, on by default;
  #   * the RESOURCE every span is exported under — service name, version,
  #     environment, tenant;
  #   * `record/2`, the ONE place a span attribute may be set.
  #
  # The last one is the whole of the redaction boundary, and its realistic
  # failure is not an attacker. It is a well-meaning engineer in six months
  # adding `span.set_attribute("customer.email", customer.email)` because it
  # would help debug a subscription, in the one service in the fleet whose rows
  # carry a customer's email, a processor id and a price in minor units. So the
  # list is the assertion, `record/2` is a choke point rather than a convention,
  # and `test/observability/canary_test.rb` plants a canary in every field a
  # caller controls and fails if it reaches an exportable attribute.
  #
  # WHY THIS FILE IS IN `lib/` AND NOT `app/lib/`, AND WHY IT IS REQUIRED
  # EXPLICITLY. It is loaded during boot, by `config/application.rb`, because the
  # middleware stack is assembled before the autoloader is set up — and a class
  # constant referenced from `config/application.rb` cannot come from an autoload
  # path without autoloading during initialization, which Rails refuses. Hence
  # `lib/` and `config.autoload_lib(ignore: %w[… kit …])`. The cost is that a new
  # file under `lib/kit/` needs a `require`; there are two of them and they are
  # in `config/application.rb` and `lib/middleware/request_telemetry.rb`.
  #
  # WHY `opentelemetry-instrumentation-rails` IS NOT HERE. Its `use_all!` records
  # `http.target`, `url.full`, `url.query` and request headers as its own span
  # attributes. Those are exactly the values a redacting collector strips, so
  # depending on the engine to strip them would make billing's boundary ONE
  # control where this repository insists on TWO. The middleware in
  # `lib/middleware/request_telemetry.rb` is hand-rolled so that what billing
  # records is only what `ALLOWED_SPAN_ATTRIBUTES` permits.
  module Telemetry
    SPAN_NAME_PREFIX = "billing"

    REQUEST_SPAN_NAME = "#{SPAN_NAME_PREFIX}.http.request"

    ENDPOINT_VARIABLE = "BILLING_OTEL_ENDPOINT"

    DEFAULT_ENDPOINT = "http://otel-collector:4318/v1/traces"

    TENANT_VARIABLE = "BILLING_TENANT_ID"

    ALLOWED_SPAN_ATTRIBUTES = %w[
      http.request.method
      http.response.status_code
      http.route
      error.type
  ].freeze

    ERROR_TYPES = %w[
      unhandled_exception
      routing_error
      middleware_error
    ].freeze

    module_function

    # THE CHOKE POINT.
    #
    #   record(span, attributes) -> span
    #
    # Sets only the attributes on `ALLOWED_SPAN_ATTRIBUTES`, drops the rest, and
    # returns the span so it can be threaded.
    #
    # Every drop is silent on purpose and the silence is worth defending: a
    # logger here would print the value it just refused, which in the case this
    # function exists for is exactly the leak. `test/observability/allowlist_test.rb`
    # asserts the drops, and asserts that a name carrying a word that means
    # content cannot be added to the list at all.
    #
    # The NAME is allowlisted and ONE VALUE is validated, and the asymmetry is
    # deliberate. `error.type` is the only attribute whose values are a closed
    # vocabulary rather than a closed *kind*, and a name check alone would let
    # `error.type` carry `PG::ConnectionBad` — unbounded cardinality from a
    # library's own naming, which is the thing the closed list exists to prevent.
    # The other three have bounded value spaces by construction (a method, a status
    # code, a route template), so a name check is the whole check they need.
    def record(span, attributes)
      return span if span.nil? || attributes.nil?

      attributes.each do |name, value|
        key = name.to_s
        next unless ALLOWED_SPAN_ATTRIBUTES.include?(key)
        next if value.nil?
        next if key == "error.type" && !ERROR_TYPES.include?(value)

        span.set_attribute(key, value)
      end
      span
    end

    # The `error.type` value for an exception, from a closed vocabulary.
    #
    # `nil` for anything unrecognised, and `nil` is the honest answer: an
    # unbounded label built from exception class names is how a dashboard ends up
    # with a legend nobody can read. The span still carries the status, so the
    # failure is visible; what it will not carry is a new series per exception
    # class.
    def error_type(exception, context)
      case context
      when :routing then "routing_error"
      when :middleware then "middleware_error"
      else
        case exception
        when Exception then "unhandled_exception"
        else nil
        end
      end
    end

    # The RESOURCE, and the argument is a `lookup` of the environment rather
    # than the environment itself, for the reason every seam in this repository
    # takes one: a test must never mutate the process environment to ask what
    # happens when a variable is set.
    #
    # Each value is APPENDED only when set. `service.version=""` is not a tidier
    # version than no version: a collector that groups by it grows a second
    # service row distinguished by an empty string, and an operator looking at a
    # service list then sees the same service twice, one of them reporting no
    # builds. Absent is the honest shape for a value nobody configured.
    def resource(lookup)
      attributes = {
        "service.name" => SPAN_NAME_PREFIX,
        "telemetry.sdk.name" => "opentelemetry",
        "telemetry.sdk.language" => "ruby"
      }
      version = lookup.call("OTEL_SERVICE_VERSION").to_s
      attributes["service.version"] = version unless version.empty?
      environment = lookup.call("DEPLOYMENT_ENVIRONMENT").to_s
      attributes["deployment.environment"] = environment unless environment.empty?
      instance = lookup.call("OTEL_SERVICE_INSTANCE_ID").to_s
      attributes["service.instance.id"] = instance unless instance.empty?
      tenant = lookup.call(TENANT_VARIABLE).to_s
      attributes["tenant_id"] = tenant unless tenant.empty?

      OpenTelemetry::SDK::Resources::Resource.create(attributes)
    end

    # Whether telemetry can be installed at all, and WHY when it cannot.
    #
    # A predicate and a reason rather than a boolean, because the alternative is
    # a boot that silently exports nothing and a service whose traces have
    # stopped without anything saying so. `log_startup` prints the reason, and the
    # tests assert the reason rather than the boolean — a boolean that went the
    # wrong way in every environment except the one that tests it is the exact
    # failure this shape exists to make visible.
    #
    # The two arguments are both answers, not answers to be fetched here: the
    # exporter name comes from Rails configuration (which environment file
    # installed which exporter is a decision a reader wants to see in that file)
    # and `disabled` is the operator's escape hatch. Fetching the second from the
    # environment inside this function would make a test have to mutate the
    # process environment to ask what a boot does, which is the thing the `lookup`
    # seam exists to prevent.
    def enabled?(exporter_name, disabled)
      return [ false, "BILLING_OTEL_DISABLED is set" ] if disabled
      return [ false, "no exporter is configured" ] if exporter_name.nil? || exporter_name.to_s.empty?

      [ true, nil ]
    end

    # One line at boot, on the enabled path AND the disabled one, because
    # configuration cannot log into the store an operator reads.
    def log_startup(logger, exporter_name, disabled, lookup)
      _ok, reason = enabled?(exporter_name, disabled)
      if reason
        logger.info("telemetry: disabled (#{reason})")
      else
        endpoint = lookup.call(ENDPOINT_VARIABLE)
        endpoint = DEFAULT_ENDPOINT if endpoint.to_s.empty?
        logger.info("telemetry: service=#{SPAN_NAME_PREFIX} exporter=#{exporter_name} endpoint=#{endpoint}")
      end
      reason
    end

    # The ROUTE TABLE, as `{ [verb, controller, action] => template }`.
    #
    # Derived from the router itself rather than written down, and that is the
    # point: a hand-written list of this service's fourteen routes is a second
    # answer to "what does the router serve", and `test/contract/http_surface_contract_test.rb`
    # already exists because two lists of routes drift.
    #
    # The key is `[verb, controller, action]` because those three are what the
    # router puts in `env["action_dispatch.request.path_parameters"]` and what it
    # will therefore have put there by the time the middleware reads it. `verb` is
    # `""` for the `via: :all` error routes, which is not a bug here: those four
    # are looked up by controller and action alone.
    def route_templates
      @route_templates ||= begin
        table = {}
        Rails.application.routes.routes.each do |route|
          defaults = route.defaults
          controller = defaults[:controller]
          action = defaults[:action]
          next if controller.nil? || action.nil?

          key = [ route.verb.to_s, controller.to_s, action.to_s ]
          table[key] ||= normalise_template(route.path.spec.to_s)
        end
        table.freeze
      end
    end

    # `/v1/customers/:id(.:format)` -> `/v1/customers/:id`.
    #
    # The optional-format suffix is stripped rather than recorded because it is
    # not part of the endpoint: a template that can also be
    # `/v1/customers/:id.json` has two values per endpoint for no reason, and the
    # collector's spanmetrics connector mints a series for each.
    def normalise_template(spec)
      spec.sub(/\(\.:format\)\z/, "")
    end

    # Forget the memoised route table. Test-only, and named as such because a
    # production caller reaching for it would be re-deriving the router's own
    # answer for no reason.
    def reset_route_templates!
      @route_templates = nil
    end
  end
end
