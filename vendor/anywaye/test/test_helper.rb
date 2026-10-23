# frozen_string_literal: true

require "minitest/autorun"

# Coverage is measured with Ruby's own `Coverage` (stdlib, branch coverage on) so
# the gate costs no gem and cannot itself carry a CVE. Started before the library
# is required, so `lib/` is measured from its first line.
require "coverage"
Coverage.start(lines: true, branches: true)

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "anywaye"

require_relative "support/database"
require_relative "support/frozen_clock"
require_relative "support/jwks_server"
require_relative "support/keys"
require_relative "support/log_capture"
require_relative "support/tokens"

module TestSupport
  # The coverage report and its floor.
  #
  # The floor started at 60% on the bootstrap commit — the gem was four lines and a
  # file of error classes at that point, and a floor of 90% over that would only
  # have been asserting that the repository does not yet contain the library. It is
  # raised at every deliverable commit: 60% at bootstrap, 90% with the verifier,
  # 95% with the outbox and the Railtie. The trajectory is in AGENTS.md.
  #
  # Raising a floor is always allowed. Lowering one, or adding an inline exclude to
  # make a build green, is not — a threshold that moves down is a gate that stopped
  # being a gate.
  module Coverage
    FLOOR = 95.0

    # This gem's `lib/`, as an absolute path.
    #
    # Not a substring match on "/lib/": the Ruby installation this suite runs
    # under keeps the standard library at `.../lib/ruby/4.0.0/...`, which matches
    # that substring, and the first version of this reporter scored 6252 lines
    # of stdlib against a repository with 60 lines in it.
    LIB_DIR = File.expand_path("../lib", __dir__)

    module_function

    def report
      measured = ::Coverage.result.select { |path, _| path.start_with?(LIB_DIR) }
      return if measured.empty?

      # `Coverage` reports `nil` for a line it does not consider executable (a
      # comment, a blank line, the `end` of a `def` under branch coverage), so
      # the denominator is the compact count: counting nils would put every file
      # in the repository at 100% the moment it was written.
      lines = measured.values.sum { |entry| entry[:lines].compact.count(&:positive?) }
      total_lines = measured.values.sum { |entry| entry[:lines].compact.count }
      # A branch entry is `{outer_key => {inner_key => count}}`, and how deep
      # that nesting goes depends on the kind of branch. Walking the whole tree
      # and counting the leaves is the shape that does not have to be corrected
      # every time Ruby adds a branch type. Counting the outer keys would count
      # *sites* rather than *arms*, and a site whose second arm was never taken
      # would report as covered.
      leaves = measured.values.flat_map { |entry| branch_counts(entry[:branches]) }
      branches = leaves.count { |count| count.positive? }
      total_branches = leaves.count

      line_percent = percent(lines, total_lines)
      branch_percent = percent(branches, total_branches)

      puts
      puts format("coverage: %.2f%% of %d lines, %.2f%% of %d branches (floor %.0f%%)",
                  line_percent, total_lines, branch_percent, total_branches, FLOOR)

      exit(1) if line_percent < FLOOR
    end

    def percent(hit, total)
      total.zero? ? 100.0 : (hit * 100.0 / total)
    end

    # Every integer leaf in a `Coverage[:branches]` tree, depth first.
    def branch_counts(node)
      case node
      when Hash then node.values.flat_map { |value| branch_counts(value) }
      when Array then node.flat_map { |value| branch_counts(value) }
      when Integer then [ node ]
      else []
      end
    end
  end

  # Minitest configuration for the suite.
  class Test < Minitest::Test
    include TestSupport::LogCapture
    include TestSupport::FrozenClock

    make_my_diffs_pretty!

    def setup
      super
      capture_logs
    end

    def teardown
      super
      TestSupport::JwksServer.all_running.each(&:stop)
    end
  end
end

Minitest.after_run { TestSupport::Coverage.report }
