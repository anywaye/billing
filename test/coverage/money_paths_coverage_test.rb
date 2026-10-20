require "test_helper"

# The coverage gate for the money paths, per PLAN §3: 100% line *and* branch
# coverage, measured with Ruby's standard library `Coverage` so the gate costs no
# gem.
#
# The measurement runs in a subprocess. That is not incidental: `Coverage` records
# only what executes after it is started, so measuring inside the minitest
# process would report a file as covered when it had merely already been
# autoloaded — a gate that passes for the wrong reason. `MoneyCoverage` runs a
# fresh process that loads the files itself; see test/support/money_coverage.rb.
#
# The corpus is shared rather than duplicated: the probe loads
# test/support/money_coverage_exercise.rb, whose every case is also asserted for
# behaviour in test/models/money_test.rb and
# test/services/subscriptions/plan_change_test.rb. A case added to cover a new
# branch is therefore a case those specs also run, and there is no second list of
# cases to forget.
class MoneyPathsCoverageTest < ActiveSupport::TestCase
  # The money paths. `money.rb` is the primitive and has been gated since
  # billing-01; `plan_change.rb` is the only place in billing-04 that compares
  # two amounts, and therefore the only place this packet could make a decision
  # on money.
  #
  # A file joins this list when it can produce or compare an amount. The
  # inventory test in this directory asserts the list against the repository, so a
  # new money path added without adding it here fails rather than going ungated.
  MONEY_PATHS = %w[
    app/models/billing/money.rb
    app/services/subscriptions/plan_change.rb
  ].freeze

  test "the money paths are fully covered, line and branch" do
    report = MoneyCoverage.measure(MONEY_PATHS)

    assert_empty report.fetch("uncovered_lines"),
      "uncovered lines in the money paths: #{report.fetch('uncovered_lines').inspect}"
    assert_empty report.fetch("uncovered_branches"),
      "uncovered branches in the money paths: #{report.fetch('uncovered_branches').inspect}"
  end

  test "the measurement actually ran, rather than reporting nothing as perfect" do
    report = MoneyCoverage.measure(MONEY_PATHS)

    assert_operator report.fetch("executable_lines"), :>, 100,
      "the gate measured almost nothing; that is not evidence of coverage"
  end

  test "every money path was measured" do
    report = MoneyCoverage.measure(MONEY_PATHS)

    assert_equal MONEY_PATHS.sort, report.fetch("files").sort
  end

  # The gate's own honesty check. A corpus that reaches almost none of the money
  # code must be *reported* as uncovered. Without this, a corpus that stopped
  # reaching the branches would look exactly like a pass, and the gate would be
  # measuring itself rather than the code.
  test "a corpus that does not reach the money paths is reported, not passed" do
    report = MoneyCoverage.measure(MONEY_PATHS, corpus: :minimal)

    assert_not_empty report.fetch("uncovered_lines"),
      "a corpus that never reached plan_change.rb was still reported as fully covered"
  end

  test "the corpus the gate measures is the one that reaches the refusals" do
    # The difference between the two corpora is the error arms, so this asserts
    # the thing the corpus is *for*: that a full pass and a minimal pass differ,
    # which is only true if the refusals are in the full one.
    full = MoneyCoverage.measure(MONEY_PATHS, corpus: :full)
    minimal = MoneyCoverage.measure(MONEY_PATHS, corpus: :minimal)

    assert_operator minimal.fetch("uncovered_lines").size, :>, full.fetch("uncovered_lines").size
  end
end
