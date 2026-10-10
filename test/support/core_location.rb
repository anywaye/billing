# Where core's schemas are, from **any** checkout of this repository.
#
# ## The hazard this exists for, measured on this machine
#
# Three tests in two files read core's real schemas and catalog, and both files
# answer "where is core" the same way: `Rails.root.join("..", "core")`. That is
# correct for the main checkout, which lives at `<root>/billing` beside
# `<root>/core`. It is **silently nil from a worktree**, because a worktree lives
# at `<root>/wt/billing-<name>` and has no `core` sibling — so
# `outbox_envelope_contract_test.rb`'s `setup` skips its 20 tests and
# `subscription_delivery_test.rb` skips its catalog test, and a run that checked
# nothing reports 0 failures.
#
# This is not a billing defect; it is every repo on this machine. Every worker
# gates in a worktree, a worktree has no `core` sibling, and a contract tier
# that skips wholesale reads exactly like a green one. BRK-4R2 was that: the
# worktree reported 21 skips and a pass, the merged tree reported 0 skips and
# one failure, and both were the same commit. The red was never in the merge —
# the worktree could not see the test that carried it.
#
# ## What this module does about it
#
# One resolution order, used by both readers, so the two cannot drift:
#
#   1. `CORE_PATH` / `CORE_SPECS_PATH` — the explicit seam, which CI sets and
#      which a standalone checkout sets. Unchanged.
#   2. `../core` beside `Rails.root` — the main checkout's answer, kept first
#      among the implicit ones because it is what the documents describe.
#   3. **the main checkout, found through git** — `git worktree list` names the
#      primary worktree, and `core` is looked for beside *that*. This is the new
#      line and the whole point: a worktree of this repository resolves the same
#      core the main checkout does.#
# A missing core still returns `nil` and the callers still skip. **The skip is
# not weakened and not deleted** — a repository cloned on its own, with no core
# beside it and no `CORE_PATH`, has no schemas to check against, and answering
# "no problem" for a document never read is the outcome a contract test exists
# to prevent. What changes is that a worktree is no longer *accidentally* in
# that state: it now finds core unless core genuinely is not there.
#
# ## Why `git worktree list` and not `git rev-parse --git-common-dir`
#
# Both name the main checkout, and the common dir is a shorter command. It is
# also a `.git` directory rather than a worktree root, and a bare repository's
# common dir is the repository itself with no parent worktree to take `..` of —
# so the common dir needs a "is this really a worktree" test beside it.
# `git worktree list --porcelain` answers the question that was asked, in the
# repository's own words, on the line-1 `worktree <path>` entry.
module TestSupport
  # Locating core, and saying so.
  module CoreLocation
    # Both ways of calling it work: `TestSupport::CoreLocation.checkout` from a
    # module, and `checkout` from a class that includes this one. A support
    # module with one calling convention is a module the second caller has to
    # reimplement.
    extend self

    # An absolute path to a core checkout, or `nil` when there is not one to
    # find. `nil` is what the callers read as "nothing to check against", and
    # they decide what to do about it.
    def checkout(explicit = nil)
      explicit = ENV["CORE_PATH"].presence || ENV["CORE_SPECS_PATH"].presence if explicit.nil?

      candidates(explicit).lazy.map { |path| expand(path) }.find { |path| readable?(path) }
    end

    # The path a reader is handed, and the one that must never be nil.
    #
    # A reader handed `nil` does not skip — it raises
    # `TypeError: no implicit conversion of nil into String` on
    # `File.join(nil, "schemas/…")`, which turns "this tier could not check
    # anything" into "this tier is broken". The deliberate skip, the one that is
    # correct for a repository cloned on its own, becomes unreachable.
    #
    # So: the resolved core, and if there is none, **where we looked**. A path
    # that does not exist is exactly what the reader's `rescue Errno::ENOENT`
    # needs in order to reach its own `skip(...)` and name somewhere an operator
    # could put core. Written here rather than at each call site, because the
    # `nil` version of this line was written and the mutation that found it was
    # the one removing the worktree candidate: the file erroring rather than
    # skipping is not what anybody goes looking for.
    def path_for
      checkout || searched.first
    end

    # The path a skip message should name, so an operator is told where to look
    # rather than told nothing. It is the same list the resolution walks, so it
    # never names a place the resolution did not try.
    def searched
      candidates(nil).map { |path| expand(path) }
    end

    private

      def candidates(explicit)
        return [ explicit ] if explicit.present?

        [ Rails.root.join("..", "core"), core_beside_primary_worktree ]
      end

      # `..`, not the worktree itself. A worktree is a checkout of *this*
      # repository and carries its own `cafaye.yml`, so resolving the worktree
      # root looks like a success and hands the caller a directory with no
      # `schemas/` in it — a skip wearing a found path's clothes. core is what is
      # beside the main checkout, and beside the main checkout is where it is
      # looked for.
      def core_beside_primary_worktree
        primary_worktree&.join("..", "core")
      end

      # The primary worktree's path, or nil. **nil, never an empty Pathname** —
      # `Pathname("").expand_path` is the process's working directory, which is
      # a real directory and, in this repository, one carrying a `cafaye.yml`. An
      # empty result would therefore validate as "found" for the very checkout
      # the lookup failed to name, which is the silent green this module exists
      # to remove.
      def primary_worktree
        line = `git worktree list --porcelain 2>/dev/null`.lines.first.to_s

        path = line[/\Aworktree\s+(.+)\s*\z/, 1].to_s.strip

        path.empty? ? nil : Pathname.new(path)
      rescue StandardError
        nil
      end

      def expand(path)
        return nil if path.blank?

        Pathname.new(path.to_s).expand_path
      end

      # What makes a directory **core** rather than another cafaye checkout. A
      # `cafaye.yml` on its own is not enough — this repository has one, and so
      # does every other service in the fleet, and the checkout it lives in is
      # exactly what a failed lookup would otherwise resolve to. The event
      # schemas are what this whole tier reads, so their presence is the
      # identification.
      def readable?(path)
        return false if path.blank?

        path.directory? && path.join("schemas").directory? && path.join("cafaye.yml").file?
      end
  end
end
