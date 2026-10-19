require "test_helper"

class SentryOffTest < ActiveSupport::TestCase
  test "sentry is unconfigured when the reporting DSN is unset" do
    assert_nil Sentry.configuration.dsn
  end
end
