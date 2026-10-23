# Shared helpers for the specs. Loaded by test/test_helper.rb.
#
# No test framework gem: everything here is Minitest plus what ActiveSupport
# already ships.
module TestSupport
  # The instant every spec pretends it is.
  #
  # A wall-clock timestamp baked into an assertion is a test that fails on a
  # different day than it was written. The clock is therefore injected — with
  # ActiveSupport's `travel_to` — and every expected timestamp is derived from
  # this one constant rather than from `Time.now`. This is why production code
  # calls `Time.current`: that is the seam the injection goes through.
  module FrozenClock
    NOW = Time.utc(2026, 9, 30, 12, 0, 0)

    def frozen_now
      NOW
    end
  end

  # Response-reading helpers for the request specs. Parsing `response.body` in
  # every test would bury the assertion under the plumbing.
  module ApiHelpers
    # The parsed response body, whatever the content type.
    def json_body
      JSON.parse(response.body)
    end

    # The `X-Trace-Id` response header. core requires it on every response.
    def trace_id_header
      response.headers["X-Trace-Id"]
    end

    # The media type with no parameters — `application/problem+json`, not
    # `application/problem+json; charset=utf-8`.
    def media_type
      response.media_type
    end

    # The fields a 422 blamed.
    def problem_codes
      json_body.fetch("errors").map { |error| error["field"] }
    end

    # Asserts the whole problem+json envelope, not just the status. Every
    # non-2xx response in this service is this shape; a helper that checked
    # only `response.status` would let the body drift.
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

    # Captures what a block logged, so a spec can assert that a cause reached
    # the log — which is the only place it is allowed to go.
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
