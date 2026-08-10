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
  # can never sweep up, strand, or clobber unrelated work on the primary checkout.
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
      porcelain.to_s.lines.filter_map do |line|
        path = line[3..].to_s.strip
        next if path.empty?

        path = path.split(" -> ").last if path.include?(" -> ")
        path unless allowed.include?(path)
      end
    end

    # True when the expected doc(s) are the ONLY things dirty in the working tree
    # — the precondition for committing to `release`. Anything else dirty → false
    # → leave it uncommitted (non-fatal: it blocks nothing, it just doesn't ship).
    def safe_to_commit?(porcelain, expected)
      other_dirty_paths(porcelain, expected).empty?
    end
  end
end
