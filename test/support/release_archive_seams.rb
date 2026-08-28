# frozen_string_literal: true

# ReleaseArchiveSeams — the FILESYSTEM FLOOR for tests that drive `bin/release
# archive`. Its sibling OutboundSeams closes the network hole; this closes the
# local one.
#
# WHY THIS EXISTS (measured 2026-08-28, not hypothesised). `archive` reaches
# outside its own process five ways: conductor, reclaim_worktrees,
# sweep_artifacts, sweep_docs and commit_artifact_to_release. Its tests stubbed
# the first two. The other three ran FOR REAL, with `apply: true`, against the
# developer's own machine:
#
#   * bin/clean-artifacts reclaimed 32.9 MB across 9 repos and 32 worktrees —
#     other agents' live desks among them — on one `bin/rails test` run.
#   * bin/archive-docs `git mv`d a doc in the PRIMARY checkout, and is not
#     idempotent: the next run dies on "fatal: destination exists". That is why
#     the suite's failure count moved 6 -> 8 on an unchanged tree, which read as
#     flakiness and taught everyone to discount its own signal.
#   * commit_artifact_to_release is the sharp one. It is gated on `return if
#     DRY`, and these tests run --yes with NO --dry-run, so DRY is false. Its
#     only other gate is ArtifactCommit.safe_to_commit?, which PERMITS the
#     commit when the expected docs are the only dirty paths — precisely the
#     state sweep_docs creates on a CLEAN primary. It then checks out `release`
#     and pushes. What prevented that was an unrelated dirty working tree, not
#     anything in the test.
#
# THE STUBS STAY FAITHFUL. Each returns the real [output, ok] pair carrying the
# genuine tagged JSON line, so sweep_summary/docs_summary still parse real input
# and the callers' summary assertions still mean something. A stub emitting more
# than the tool does would certify broken parsing as green.
module ReleaseArchiveSeams
  # Every seam `archive` uses to touch the filesystem. Interpolate into a stub
  # passed as `run_cli(..., setup:)`. Add to it whenever a new seam appears —
  # SHELL_POISON below will tell you when one has.
  ISOLATION_STUB = <<~RUBY.freeze
    def sweep_artifacts(apply:)
      payload = { dry_run: !apply, reclaimed_bytes: 1024, reclaimed_human: "1 KB",
                  repos: 2, worktrees: 3, rotation_missing: [], rotation_unknown: [],
                  audited_envs: [] }
      ["==> \#{apply ? 'Reclaimed' : 'Would reclaim'} 1 KB\\n" \\
       "clean-artifacts-summary: \#{JSON.generate(payload)}\\n", true]
    end
    def sweep_docs(apply:)
      payload = { dry_run: !apply, moved: 1, moved_paths: ["docs/agents/audits/stub.md"],
                  skipped: [], ledger_rolled: 2, ledger_cutoff: nil }
      ["==> \#{apply ? 'Retired' : 'Would retire'} 1 doc(s)\\n" \\
       "archive-docs-summary: \#{JSON.generate(payload)}\\n", true]
    end
    def commit_artifact_to_release(repo, paths, message)
      nil
    end
  RUBY

  # Poison every shell primitive bin/release.rb owns. Any un-stubbed path that
  # tries to reach the machine RAISES with the command named, BEFORE it runs —
  # which is the point: diffing `git status` around a run can only report a
  # mutation that already happened, and the mutation is what we are preventing.
  SHELL_POISON = <<~RUBY.freeze
    module Open3
      def self.capture2e(*cmd, **) = raise("SHELL ESCAPE: Open3.capture2e \#{cmd.inspect}")
      def self.capture3(*cmd, **)  = raise("SHELL ESCAPE: Open3.capture3 \#{cmd.inspect}")
    end
    def sh(*cmd, **) = raise("SHELL ESCAPE: sh \#{cmd.inspect}")
  RUBY
end
