# frozen_string_literal: true

require_relative "../kit/telemetry"

# The request span, and the whole of billing's HTTP telemetry.
#
# A Rack middleware rather than `opentelemetry-instrumentation-rack`, and the
# reason is in `Kit::Telemetry`: the contrib instrumentation records `http.target`,
# `url.full`, `url.query` and request headers as its own span attributes. Those are
# exactly the values a redacting collector strips, so depending on the engine to
# strip them would make billing's boundary ONE control where this repository
# insists on TWO. Hand-rolled, billing records only what the allowlist permits.
#
# WHY IT SITS AT THE VERY OUTSIDE OF THE STACK. Two halves of what it records pull
# in opposite directions, and the placement is the resolution of both:
#
#   * the STATUS is on the response, so it can only be read after `@app.call`
#     returns — reading it before would read the status Rack was about to write
#     over;
#   * the ROUTE is in `env["action_dispatch.request.path_parameters"]`, which Rails
#     fills in WHILE routing, on the same env hash this middleware holds. An outer
#     middleware that kept the env would see it; one that read it on the way IN
#     would not, and a 404 and a 405 would have no span at all.
#
# A 404 is therefore covered, and it is covered with NO route: the path of an
# unmatched request is caller-controlled text, so recording it is the cardinality
# bomb and the content leak in one move. The 404 status is the answer.
#
# `start_span` + an explicit `finish`, and NOT `tracer.in_span`. Two reasons, both
# about what `in_span` puts on a span of its own accord:
#
#   * `in_span` calls `span.record_exception(e)` by default, which attaches the
#     exception's CLASS NAME, MESSAGE and STACKTRACE as a span EVENT — and an
#     event is exported. An exception message in this service is built three frames
#     up from what a caller sent, and `test/integration/secrets_do_not_leak_test.rb`
#     exists because that is where leaks live.
#   * `in_span` then sets the status description to
#     `"Unhandled exception of type: #{e.class}"`, which is an exception class name
#     on an exported span, written by code this repository does not control and
#     cannot allowlist.
#
# So the span's status, its attributes and its events are all decided here, where
# they can be allowlisted. The span still ENDS with an error status and an
# `error.type` from a closed vocabulary — the failure is fully visible, and nothing
# about it is free text.
class RequestTelemetry
  PATH_PARAMETERS = "action_dispatch.request.path_parameters"

  RACK_ENV_GETTER = OpenTelemetry::Common::Propagation.rack_env_getter

  FAILURE_DESCRIPTION = "the request could not be completed"

  def initialize(app, tracer: nil, lookup: nil)
    @app = app
    @lookup = lookup || ->(name) { ENV.fetch(name, "") }
    @tracer = tracer || OpenTelemetry.tracer_provider.tracer(Kit::Telemetry::SPAN_NAME_PREFIX)
  end

  def call(env)
    span = @tracer.start_span(
      Kit::Telemetry::REQUEST_SPAN_NAME,
      with_parent: OpenTelemetry.propagation.extract(env, getter: RACK_ENV_GETTER),
      kind: :server
    )
    Kit::Telemetry.record(span, { "http.request.method" => env["REQUEST_METHOD"] })

    begin
      OpenTelemetry::Trace.with_span(span) do
        begin
          status, headers, body = @app.call(env)
        rescue Exception => exception # rubocop:disable Lint/RescueException
          Kit::Telemetry.record(span, {
            "http.response.status_code" => 500,
            "error.type" => Kit::Telemetry.error_type(exception, :unhandled)
          })
          fail_span(span)
          raise
        end

        Kit::Telemetry.record(span, { "http.response.status_code" => status.to_i })
        mark_error(span, status)
        route = route_template(env)
        Kit::Telemetry.record(span, { "http.route" => route }) if route

        [ status, headers, body ]
      end
    rescue
      raise
    end
  ensure
    # `SimpleSpanProcessor` exports synchronously on `finish`, which can block
    # the request thread for the exporter's full timeout when the collector is
    # slow or unreachable — and that delay keeps the response from leaving the
    # socket. In tests the exporter is in-process and instant, so finishing
    # synchronously keeps the span visible to the assertions. In production the
    # finish runs on a background thread so the export never blocks the
    # response.
    finish_span(span) if Rails.env.test?
    Thread.new { finish_span(span) } unless Rails.env.test?
  end

  def finish_span(span)
    return if span.nil?
    begin
      span.finish
    rescue
      # Export failures must never propagate out of the request path.
    end
  end
  private

  # A 5xx marks the span an error and a 4xx does not.
  #
  # The line between them is the whole of this method and it is a decision rather
  # than a convention: a 401 or a 404 is this service REFUSING a caller, which is
  # this service working. An error rate that counts them is a function of how much
  # guessing the internet absorbs, and an alert on it pages somebody to switch off
  # the protection doing its job.
  def mark_error(span, status)
    code = status.to_i
    return if code < 500

    Kit::Telemetry.record(span, { "error.type" => "unhandled_exception" })
    fail_span(span)
  end

  def fail_span(span)
    span.status = OpenTelemetry::Trace::Status.error(FAILURE_DESCRIPTION)
  end

  # The route TEMPLATE, looked up in the router's own table, and nil for a request
  # that matched nothing.
  #
  # Looked up rather than read off the request, because `path_parameters` holds the
  # controller, the action AND the caller's own `:id` — and that `:id` is exactly
  # the value that must not be exported. The template comes from
  # `Kit::Telemetry.route_templates`, which is derived from `config/routes.rb`.
  #
  # The second lookup is for the four `via: :all` error routes, whose `verb` is
  # `""` in the route set; they are addressed by method and path by `match`, so a
  # request to `/404` is a `GET` and the verb-keyed entry is empty.
  def route_template(env)
    parameters = env[PATH_PARAMETERS]
    return nil unless parameters.is_a?(Hash)

    controller = parameters[:controller]
    action = parameters[:action]
    return nil if controller.nil? || action.nil?

    table = Kit::Telemetry.route_templates
    key = [ env["REQUEST_METHOD"].to_s, controller.to_s, action.to_s ]
    table[key] || table[[ "", controller.to_s, action.to_s ]]
  end
end
