class Release
  # Pure decision for committing a generated doc — a `bin/release retro` doc or the
  # `delete-later.md` ledger that `archive` updates — onto the `release` branch,
  # instead of leaving it to pile up as uncommitted working-tree dirt in the primary.
  # (It no longer BLOCKS a ship — the deploy runs from its own workspace and only
  # advises on a dirty primary — but an uncommitted generated doc that never ships
  # is still drift.)
  #
  # IO-free like Release::ShipSequence / Release::GemfileRepin: it takes a
  # `git status --porcelain` listing in and returns arrays/booleans out; bin/release
  # owns the fetch/checkout/commit/push around it (and `require`s this file directly
  # — no Rails deps).
  #
  # The one decision: bin/release may do its transient `git checkout release` +
  # commit ONLY when the target doc is the SOLE uncommitted change — so the dance
  # can never sweep up, strand, or clobber unrelated work on the primary checkout,
  # and never flips a SHARED checkout to discover it had nothing to do. Both
  # halves of "sole uncommitted change" are enforced: something expected is dirty,
  # and nothing else is.
  module ArtifactCommit
    module_function

    # The working-tree paths dirty OTHER than the expected one(s), parsed from
    # `git status --porcelain`. Each line is "XY <path>" (or "XY <old> -> <new>"
    # for a rename — the NEW path is the live one). The expected docs (committed
    # to `release` on purpose) and blank lines are excluded.
    #
    # `expected` takes one path OR many. Many exists for the archive beat's docs
    # sweep, which retires a whole batch of frozen snapshots in one `git mv` pass
    # plus rewrites the ledger — one logical change across N paths. Passing only
    # the ledger there would read the retirements as "unrelated work", refuse the
    # commit, and strand a dozen staged renames as dirt on the primary checkout.
    def other_dirty_paths(porcelain, expected)
      allowed = Array(expected)
      dirty_paths(porcelain).reject { |path| allowed.include?(path) }
    end

    # The expected doc(s) that are ACTUALLY dirty. Empty ⇒ there is nothing to
    # commit, and `bin/release` must not flip the checkout to find that out.
    #
    # An artifact that does not exist yet is UNTRACKED (`?? path`), which
    # porcelain reports like any other change, so a FIRST RUN reads as dirty and
    # still commits. That is the case this must not turn into a no-op.
    def expected_dirty_paths(porcelain, expected)
      allowed = Array(expected)
      dirty_paths(porcelain).select { |path| allowed.include?(path) }
    end

    # Nothing staged, nothing changed — the artifact regenerated to the same
    # bytes, or was never touched. NOT a refusal: there is simply no work.
    def nothing_to_commit?(porcelain, expected)
      expected_dirty_paths(porcelain, expected).empty?
    end

    # True when the expected doc(s) are the ONLY things dirty in the working tree
    # — the precondition for committing to `release`. Anything else dirty → false
    # → leave it uncommitted (non-fatal: it blocks nothing, it just doesn't ship).
    # NOTHING dirty → also false: there is no commit to make.
    #
    # THE CODE MOVED TO MEET THIS COMMENT, not the other way round (2026-09-13).
    # The sentence above always claimed the expected docs ARE the only things
    # dirty — a conjunction — while the body asserted only the second half,
    # `other_dirty_paths(...).empty?`, which a CLEAN tree satisfies vacuously. So
    # `commit_artifact_to_release` ran its `checkout release` → `git commit`
    # (silently a no-op with nothing staged) → `ensure { checkout main }` dance on
    # runs with nothing to commit. Measured on the hub primary 2026-09-10: 191
    # flip pairs and ZERO `commit:` entries in 400 reflog records, median dwell on
    # `release` 1s. Each of those flips opens a ~0.4-0.7s window (~68% of a
    # checkout) in which every tracked file briefly does not exist — the window
    # that cost four measured failures in one day across three sessions.
    def safe_to_commit?(porcelain, expected)
      !nothing_to_commit?(porcelain, expected) && other_dirty_paths(porcelain, expected).empty?
    end

    # ONE parser for both halves. Each porcelain line is "XY <path>" (or
    # "XY <old> -> <new>" for a rename — the NEW path is the live one). Splitting
    # this into two nearly-identical loops is how the two halves drift into
    # disagreeing about what a dirty path is.
    def dirty_paths(porcelain)
      porcelain.to_s.lines.filter_map do |line|
        path = line[3..].to_s.strip
        next if path.empty?

        path.include?(" -> ") ? path.split(" -> ").last : path
      end
    end
  end
end
