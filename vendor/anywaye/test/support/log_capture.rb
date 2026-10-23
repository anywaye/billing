# frozen_string_literal: true

require "stringio"
require "logger"

module TestSupport
  # Captures whatever the library writes to any logger, so the canary test can
  # assert on the rendered text rather than on a list of attribute names.
  #
  # Asserting attribute-by-attribute only proves the filter catches the names
  # somebody already thought of. The canary string is a value, and the only
  # assertion that survives is the one over the whole rendered output: every
  # message, at every level, through whatever logger the library happens to
  # reach. That is why this hooks the logger rather than a method — a library
  # that logs through `warn` and one that logs through `info` are both caught,
  # and one that adds a new destination later is caught the first time it runs.
  module LogCapture
    LOG_DEVICE = "anywaye-test-log-device"

    def capture_logs
      @log_stream = StringIO.new
      @logger = Logger.new(@log_stream)
      @logger.level = Logger::DEBUG
      @previous_logger = Anywaye.logger
      Anywaye.logger = @logger
    end

    # Everything written, at every level, as one string. The assertion target.
    def logged_output
      @log_stream.string
    end

    def restore_logs
      Anywaye.logger = @previous_logger
    end
  end
end
