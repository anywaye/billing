module TestSupport
  module FrozenClock
    NOW = Time.utc(2026, 9, 30, 12, 0, 0)

    def frozen_now
      NOW
    end
  end

  module ApiHelpers
    def json_body
      JSON.parse(response.body)
    end

    def trace_id_header
      response.headers["X-Trace-Id"]
    end

    def media_type
      response.media_type
    end

    def problem_codes
      json_body.fetch("errors").map { |error| error["field"] }
    end

    def assert_problem(code)
      body = json_body

      assert_equal "application/problem+json", media_type
      assert_equal code, body["code"]
      assert_equal "https://docs.anywaye.com/errors/#{code}", body["type"]
      assert_equal response.status, body["status"]
      assert_equal request.path, body["instance"]
      assert_equal trace_id_header, body["trace_id"]
      assert_kind_of String, body["title"]
      assert_kind_of String, body["detail"]
    end

    def capture_log
      buffer = StringIO.new
      previous = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(buffer)
      yield
      buffer.string
    ensure
      Rails.logger = previous
    end
  end
end
