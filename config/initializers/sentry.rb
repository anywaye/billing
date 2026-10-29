# frozen_string_literal: true

Sentry.init do |config|
  config.dsn = ENV["BILLING_ERROR_REPORTING_DSN"]
  config.release = ENV["BILLING_RELEASE"].presence || ENV["COURIER_RELEASE"].presence || "unknown"
  config.environment = ENV["DEPLOYMENT_ENVIRONMENT"].presence || "production"
  config.send_default_pii = false

  config.before_send = lambda do |event, _hint|
    if event.exception && event.exception.values
      event.exception.values.each do |exc|
        exc.value = nil
      end
    end
    if event.request
      event.request.url = nil
      event.request.query_string = nil
      trace_id = event.request.headers&.[]("X-Trace-Id") || event.request.headers&.[]("x-trace-id")
      event.tags = (event.tags || {}).merge("trace_id" => trace_id) if trace_id
    end
    event
  end
end
