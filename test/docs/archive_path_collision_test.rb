# frozen_string_literal: true

require "test_helper"
require "open3"
require Rails.root.join("bin", "lib", "docs_archive").to_s

# Tripwire for the defect in /tasks/duplicate-doc-blocks-archive: a doc tracked
# at BOTH its live path and its mirrored archive path.
#
# WHAT IT COSTS WHEN IT HAPPENS. DocsArchive retires a qualifying doc with a
# `git mv` onto DocsArchive.archive_path_for(path). If something is already
# tracked there, git refuses:
#
#   git mv docs/agents/maintenance/open-pr-decisions-2026-08-26.md \
#          docs/agents/archive/maintenance/open-pr-decisions-2026-08-26.md
#   fatal: destination exists
#
# That is not a per-file skip. It aborts the roll, so ONE duplicated file blocks
# the archiving of EVERY other qualifying doc, indefinitely. The live instance
# blocked every docs archive from 2026-08-31 (when it was introduced) until it
# was removed, and it separately blocked a fast-forward of the hub primary when
# the untracked working copy collided with the incoming tracked one.
#
# HOW IT GOT IN, which is why a guard and not just a sweep: commit cfa5996e ADDED
# the archive copy (`A`, 126 insertions) and left the live copy tracked. A copy
# where a move was meant. Nothing in the tree objected, and the next archive roll
# inherited the wreckage — days later, in someone else's session, reported as a
# ledger-conservation error. Removing the one instance fixes today; this makes it
# fail HERE, in the diff that reintroduces it.
#
# WHY IT BINDS TO archive_path_for RATHER THAN RESTATING THE MAPPING. The rule
# ("same subdirectory, under the archive root") lives in bin/lib/docs_archive.rb.
# A guard with its own copy of that rule stops matching the archiver the moment
# the mapping is changed and then proves nothing while still passing green. This
# calls the real method, so it tracks the archiver by construction.
class ArchivePathCollisionTest < ActiveSupport::TestCase
  ARCHIVE_DIR = DocsArchive::ARCHIVE_DIR

  # Every (live, archive) pair where BOTH paths are present in `paths`.
  #
  # Sources under the archive root are skipped, matching DocsArchive's own rule 1
  # (`frozen_shape?` returns false for anything already archived). Without that
  # skip an archived file would be measured against a doubly-nested
  # docs/agents/archive/archive/... path that means nothing.
  def collisions(paths)
    present = paths.to_h { |p| [p, true] }
    paths
      .reject { |p| p.start_with?("#{ARCHIVE_DIR}/") }
      .map { |p| [p, DocsArchive.archive_path_for(p)] }
      .select { |_live, archived| present[archived] }
  end

  # ---- [unit] the detector itself ----------------------------------------
  #
  # These exist so the integration assertion below cannot pass vacuously. A
  # detector that returned [] unconditionally would keep the real-tree test green
  # forever while catching nothing; the positive cases here are what prove it
  # bites, and the negative cases are what prove it will not cry wolf.

  test "[unit] a doc tracked at both its live and mirrored archive path is a collision" do
    paths = %w[
      docs/agents/maintenance/open-pr-decisions-2026-08-26.md
      docs/agents/archive/maintenance/open-pr-decisions-2026-08-26.md
    ]
    assert_equal [paths], collisions(paths).map { |pair| pair.map(&:itself) },
      "the exact shape of the shipped defect must be detected"
  end

  test "[unit] a doc outside docs/agents/ mirrors under the archive root too" do
    paths = %w[docs/topics/retro-rel-1.md docs/agents/archive/topics/retro-rel-1.md]
    assert_equal 1, collisions(paths).size,
      "archive_path_for strips docs/ as well as docs/agents/, so docs/topics collides too"
  end

  test "[unit] a doc tracked at exactly one path is not a collision" do
    assert_empty collisions(%w[
      docs/agents/maintenance/open-pr-decisions-2026-08-26.md
      docs/agents/archive/maintenance/some-other-file.md
      docs/agents/modules/testing.md
    ])
  end

  test "[unit] a shared basename in two different subdirectories is not a collision" do
    # docs/agents/agents/*/role.md repeats a basename across ten directories and
    # is entirely correct. The rule is the MIRRORED PATH, not the basename — a
    # basename-only check would fail this repo on ~20 innocent files.
    assert_empty collisions(%w[
      docs/agents/agents/avi/role.md
      docs/agents/agents/carl/role.md
      docs/agents/archive/agents/steffon/role.md
    ])
  end

  test "[unit] an already-archived doc is not measured against a doubly-nested path" do
    assert_empty collisions(%w[
      docs/agents/archive/maintenance/f.md
      docs/agents/archive/archive/maintenance/f.md
    ]), "sources under the archive root are skipped, matching DocsArchive rule 1"
  end

  # ---- [integration] the real tracked tree -------------------------------

  test "[integration] no doc is tracked at both a live and an archive path" do
    out, status = Open3.capture2e("git", "-C", Rails.root.to_s, "ls-files", "--", "docs/")
    assert status.success?, "git ls-files failed: #{out}"

    tracked = out.lines.map(&:chomp).reject(&:empty?)
    # Guard the guard: an empty listing would make the assertion below vacuous.
    assert_operator tracked.size, :>, 50, "expected the docs tree to be tracked and non-trivial"

    found = collisions(tracked)
    assert_empty found, <<~MSG
      #{found.size} doc(s) are tracked at BOTH a live and an archive path.

      #{found.map { |live, archived| "  live:    #{live}\n  archive: #{archived}" }.join("\n\n")}

      DocsArchive retires docs with `git mv <live> <archive>`, which fails with
      "fatal: destination exists" and ABORTS THE WHOLE ROLL — so this blocks the
      archiving of every other qualifying doc, not just these.

      Fix: keep ONE copy. Diff them first (`git diff <live> <archive>`); the
      archive path is normally the one to keep, since that is where the roll is
      trying to put it. If the two have diverged, resolve it deliberately and say
      why in the commit — do not delete the divergence silently.
    MSG
  end
end
