require "test_helper"

# The core checkout is found, from **this** worktree, with nothing configured.
#
# ## Why this file exists
#
# BRK-4R2 was a green worktree and a red main checkout on the same commit. Both
# trees were at `44ca9f6`; neither had a patch. The difference was environmental,
# and it is the single most valuable thing that packet found:
#
#   `default_core_path` was `Rails.root.join("..", "core")`. That resolves beside
#   the **main** checkout, at `<root>/billing`/`<root>/core`. A worktree lives at
#   `<root>/wt/billing-<name>` and has no `core` sibling, so the path did not
#   exist, `setup` in `outbox_envelope_contract_test.rb` skipped its 20 tests,
#   `subscription_delivery_test.rb` skipped its catalog test, and a run that
#   checked nothing reported 0 failures. 21 skips, a pass, and the one payload
#   contract test in the fleet silently unchecked.
#
# This is not a billing defect and it is not that test's. It is every repository
# on this machine: every worker gates in a worktree, a worktree has no `core`
# sibling, and a contract tier that skips wholesale is indistinguishable from a
# green one. The fix is `TestSupport::CoreLocation`, and **this is the file that
# proves it still resolves from a worktree**, so the day someone shortens the
# resolution back to the sibling path, this fails by name rather than the fleet
# quietly losing the tier again.
#
# ## What it deliberately does not do
#
# It does not remove the skip. A repository cloned on its own has no core beside
# it and no `CORE_PATH`, and answering "no problem" for a schema never read is
# the outcome a contract test exists to prevent — so `checkout` returning `nil`
# there is correct and is asserted below. What changed is that a **worktree** is
# no longer accidentally in that state.
class CoreLocationTest < ActiveSupport::TestCase
  # The property BRK-4R2 was missing, stated as a fact about this directory
  # rather than about a path.
  #
  # `CORE_PATH` is cleared for this test rather than inherited, because the whole
  # point is that the resolution works with nothing configured — a run that
  # inherits a `CORE_PATH` from the shell would pass here for the wrong reason and
  # prove nothing about a worktree.
  test "core is found from this checkout with nothing configured" do
    with_env("CORE_PATH" => nil, "CORE_SPECS_PATH" => nil) do
      core = TestSupport::CoreLocation.checkout

      assert core.present?, "core was not found from #{Dir.pwd}, and that is the BRK-4R2 hazard"

      # A path that exists is not a core checkout. The tiebreaker is what is
      # inside it: the event schemas are the entire reason this tier reads core,
      # and `cafaye.yml` alone is what a failed lookup lands on, because the
      # worktree has one too.
      assert File.directory?(core.join("schemas").to_s),
        "the resolved path has no schemas/ in it, so it is not core"
      assert File.file?(core.join("cafaye.yml").to_s),
        "the resolved path is not a cafaye checkout at all"
      assert File.file?(core.join("schemas", "event-envelope.schema.json").to_s),
        "the resolved path is core but has no envelope schema, which is what this tier reads first"
    end
  end

  # The bug this module had on first write, kept as a test because it read as
  # correct and behaved silently.
  #
  # `primary_worktree` returned `Pathname.new("")` when git named nothing.
  # `Pathname("").expand_path` is the process's working directory — a real
  # directory, and in this repository one carrying a `cafaye.yml` — so the empty
  # result validated as "found" and `checkout` answered *the worktree itself*.
  # The skip message then named a path that existed, which is worse than naming
  # a path that does not.
  test "a lookup that names nothing resolves nothing, not the working directory" do
    with_env("CORE_PATH" => nil, "CORE_SPECS_PATH" => nil) do
      simple_stubs.stub_object(TestSupport::CoreLocation, :primary_worktree) { nil }

      nothing = TestSupport::CoreLocation.checkout

      assert_not_equal Dir.pwd, nothing.to_s,
        "an empty worktree lookup resolved the working directory, which is a real directory and reads as found"
    end
  ensure
    simple_stubs.unstub_all!
  end

  # A worktree resolves *core*, which is outside it. This is the one-line
  # statement of the bug, and it is asserted rather than left as a comment
  # because the failure mode it names produced a green run.
  test "what a worktree resolves is outside the worktree" do
    with_env("CORE_PATH" => nil, "CORE_SPECS_PATH" => nil) do
      core = TestSupport::CoreLocation.checkout.to_s

      assert_not core.start_with?("#{Rails.root}/"),
        "core resolved to something inside this checkout: #{core}"
    end
  end

  # The seam CI uses, which must keep working and must keep winning. Without this
  # the `gate` job in CI would silently resolve through git instead, and a
  # `CORE_PATH` that stopped mattering would take months to notice.
  #
  # Two properties, and the second is the one that matters: an explicit path is
  # answered verbatim, and an explicit path that is not core does **not** fall
  # through to the implicit list. A resolution that quietly widened an explicit
  # answer would be a resolution nobody could point at a checkout.
  test "an explicit CORE_PATH is what the resolution answers, and it does not fall through" do
    core = TestSupport::CoreLocation.checkout

    assert core.present?, "no core checkout resolved, so this test has nothing to point at"

    assert_equal core.to_s, TestSupport::CoreLocation.checkout(core).to_s,
      "an explicit path was not honoured verbatim"

    assert_nil TestSupport::CoreLocation.checkout(Rails.root.join("..")),
      "an explicit path that is not core fell through to the implicit list " \
      "instead of being answered with nothing"
  end

  test "the CORE_PATH environment variable is the seam CI sets, and it is read" do
    core = TestSupport::CoreLocation.checkout

    assert core.present?

    with_env("CORE_PATH" => core.to_s, "CORE_SPECS_PATH" => nil) do
      assert_equal core.to_s, TestSupport::CoreLocation.checkout.to_s,
        "CORE_PATH was not read, so the seam CI's gate job uses does not work"
    end
  end

  # The path a reader is handed, and the one that must never be nil.
  #
  # A reader handed `nil` does not skip: it raises `TypeError` on
  # `File.join(nil, "schemas/…")`, which turns "this tier could not check
  # anything" into "this tier is broken" and makes the deliberate skip
  # unreachable. **This was written wrong and the mutation that caught it was
  # the one removing the worktree candidate**: the file erroring rather than
  # skipping is not what anybody goes looking for.
  test "a reader is handed a path even when there is no core, so its skip is reachable" do
    nowhere = Pathname.new("/nonexistent-core-checkout")

    simple_stubs.stub_object(TestSupport::CoreLocation, :checkout) { nil }
    simple_stubs.stub_object(TestSupport::CoreLocation, :searched) { [ nowhere ] }

    handed = TestSupport::CoreLocation.path_for

    assert handed.present?, "a reader was handed nil, which raises TypeError rather than skipping"
    assert_raises(Errno::ENOENT) do
      File.read(File.join(handed.to_s, "schemas", "event-envelope.schema.json"))
    end

    refute File.directory?(handed.to_s),
      "the fallback path exists, so a reader would find files in a directory that is not core"
  ensure
    simple_stubs.unstub_all!
  end

  # `nil` is the honest answer when there is genuinely no core, and the callers
  # turn it into a skip. The skip is not being removed — this is the assertion
  # that says so, so a future change to "raise" or "guess" fails here.
  test "a checkout with no core anywhere answers nil, which the callers read as nothing to check" do
    simple_stubs.stub_object(TestSupport::CoreLocation, :primary_worktree) { nil }
    simple_stubs.stub_object(TestSupport::CoreLocation, :readable?) { |_path| false }

    assert_nil TestSupport::CoreLocation.checkout,
      "nothing was found, and the resolution answered something anyway"
  ensure
    simple_stubs.unstub_all!
  end

  # The skip message names where to look. An operator who is told nothing cannot
  # act, and "core is not on disk" without a path is that — which is how a fleet
  # ends up working around a skipped tier for a month.
  test "the paths the resolution tried are named, and the first is the sibling beside this checkout" do
    with_env("CORE_PATH" => nil, "CORE_SPECS_PATH" => nil) do
      searched = TestSupport::CoreLocation.searched

      assert_not_empty searched, "the resolution tried nowhere, so a skip message would name nothing"
      assert_equal Rails.root.join("..", "core").expand_path.to_s, searched.first.to_s
    end
  end

  # One resolution, two readers. `outbox_envelope_contract_test.rb` and
  # `subscription_delivery_test.rb` answered "where is core" independently when
  # they were written, and the two answers were the same until one of them was
  # right and the other was not — which is what a worktree is.
  test "the two readers that used to answer this alone both resolve core now" do
    with_env("CORE_PATH" => nil, "CORE_SPECS_PATH" => nil) do
      core = TestSupport::CoreLocation.checkout

      assert File.readable?(core.join("docs", "event-naming.md").to_s),
        "the catalog the delivery test reads is not at the resolved path"
      assert File.readable?(core.join("schemas", "event-envelope.schema.json").to_s),
        "the envelope schema the contract test reads is not at the resolved path"
    end
  end
end
