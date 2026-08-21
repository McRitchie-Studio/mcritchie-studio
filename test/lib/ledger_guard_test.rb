# frozen_string_literal: true

# THE MOVE-NEVER-DELETE INVARIANT of the delete-later ledger, and the guard that holds it
# when the writer that touched the ledger is a STALE COPY of bin/agent-worktree.
#
# WHAT HAPPENED. `docs/agents/maintenance/delete-later.md` states that rows are MOVED to
# `docs/agents/archive/maintenance/delete-later-archive.md`, never deleted. On 2026-08-21
# three rows left the pair entirely — readable at `git show origin/accepted:…` and absent
# from BOTH files afterwards:
#
#   /Users/alex/projects/mcritchie-studio/.worktrees/_ship                     (HEAD d7ccca8d)
#   /Users/alex/projects/turf-monster/.worktrees/_ship                         (HEAD 1ada513)
#   /Users/alex/projects/mcritchie-studio/.worktrees/shrink-agent-portrait-assets (HEAD d4077fb0)
#
# All three are RECYCLED desk paths. A teardown overwrote their dated 08-20 rows IN PLACE
# with 08-21 rows, so the archive roll never saw the originals and archived 40 of the 43
# rows that left the file. bin/lib/docs_archive.rb is not at fault: split_ledger is pure
# and has no drop path.
#
# WHY THE WRITER FIX IS NOT THE FIX. Commit 269e2db4 already taught
# `open_ledger_row_index` to skip DATED rows, and test/lib/agent_worktree_test.rb pins
# that behaviour. But `ledger_path` is anchored to HUB_DIR, so a teardown driven from ANY
# desk mutates the HUB's ledger with whatever logic THAT DESK happens to carry — and 12 of
# 18 hub worktrees were still carrying the pre-fix script when this was measured. The
# fingerprint is in the data: the replacement `_ship` row records HEAD be798149, the hub
# primary's own pre-fix commit. Fixing the writer a second time cannot protect a file that
# stale copies can write.
#
# SO THE GUARD DOES NOT LIVE IN THE WRITER. It lives where the change becomes DURABLE —
# the committed tree, read by this test in the `rails` CI lane on every PR and on every
# push to accepted/release/main. Whichever desk produced the diff, the diff cannot land on
# `accepted` while it destroys a resolved row: the lane goes red and NAMES the rows. The
# rows are still recoverable from the base ref at exactly that moment, which is the whole
# value of catching it here rather than by a reviewer who happened to run `comm`.
#
# Run directly:
#   ruby -Itest test/lib/ledger_guard_test.rb

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../../bin/lib/ledger_guard"

class LedgerGuardTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CLI  = File.join(ROOT, "bin", "ledger-guard")

  # The base refs the live check will accept, best first. Feature PRs are based on
  # `accepted`; `release` and `main` cover a push to a shippable tip whose `accepted` has
  # since moved on. Every one of them is compared at its MERGE BASE with HEAD, so the
  # comparison is always against a genuine ancestor of this tree — never against a sibling
  # branch that is merely ahead, which would paint a healthy checkout red.
  BASE_REFS = %w[origin/accepted origin/release origin/main].freeze

  HEADER = <<~MD
    # Delete Later Ledger

    | Path | Type | Why it is a candidate | Safe-delete condition | Status |
    |------|------|-----------------------|-----------------------|--------|
  MD

  SHIP = "/Users/alex/projects/mcritchie-studio/.worktrees/_ship"

  def row(path, status, reason: "Hidden worktree; branch is clean.", condition: "Remove after approval.")
    "| `#{path}` | worktree | #{reason} | #{condition} | #{status} |\n"
  end

  # ================================================================================
  # [unit] the invariant itself — a resolved (dated) row is immutable history
  # ================================================================================

  # THE REGRESSION. The incident shape, verbatim: one recycled path, its 08-20 teardown
  # row replaced IN PLACE by the 08-21 teardown. The pair of files after the write holds
  # no trace of the 08-20 episode, and that is what the guard must say out loud.
  def test_unit_a_recycled_path_overwritten_in_place_is_reported_lost
    base = HEADER + row(SHIP, "removed 2026-08-20", reason: "Hidden worktree at HEAD d7ccca8d.")
    head = HEADER + row(SHIP, "removed 2026-08-21", reason: "Hidden worktree at HEAD be798149.")

    lost = LedgerGuard.lost(base: [base], head: [head])

    assert_equal 1, lost.size,
                 "the 08-20 teardown is gone from both files — that is the destroyed row " \
                 "this guard exists to refuse"
    assert_equal SHIP, lost.first.path
    assert_equal "removed 2026-08-20", lost.first.status
    assert_includes lost.first.line, "d7ccca8d",
                    "the report must carry the WHOLE lost row, so it can be pasted back"
  end

  # THE OTHER DIRECTION, and the reason the invariant is not "the ledger never changes".
  # The archive roll MOVES resolved rows out of the ledger and into the archive. That is
  # the sanctioned path, and a guard that flagged it would be turned off within a week.
  def test_unit_a_roll_into_the_archive_is_not_a_loss
    resolved = row(SHIP, "removed 2026-08-20")
    base = [HEADER + resolved, HEADER]
    head = [HEADER, HEADER + resolved]

    assert_empty LedgerGuard.lost(base: base, head: head),
                 "moving a row from the ledger to its archive is the invariant being KEPT"
  end

  # An UNDATED row ("pending approval", "reference only") is an open item, not history.
  # The teardown that resolves it closes it in place, which changes its text and removes
  # the undated row from the file. Counting those as history would make every legitimate
  # teardown a violation.
  def test_unit_closing_an_open_row_in_place_is_not_a_loss
    base = HEADER + row(SHIP, "pending approval")
    head = HEADER + row(SHIP, "removed 2026-08-21")

    assert_empty LedgerGuard.lost(base: [base], head: [head]),
                 "an open row is not yet history; resolving it is the state transition the " \
                 "ledger is FOR"
  end

  # The fixed writer's behaviour: a recycled path gets a row per teardown, side by side.
  def test_unit_a_second_teardown_appended_beside_the_first_is_not_a_loss
    base = HEADER + row(SHIP, "removed 2026-08-20")
    head = base + row(SHIP, "removed 2026-08-21")

    assert_empty LedgerGuard.lost(base: [base], head: [head])
  end

  # The archive is append-only BY DESIGN, and it is half of the union. A row deleted from
  # it is exactly as lost as a row deleted from the ledger, so the guard reads both.
  def test_unit_a_row_dropped_from_the_archive_is_reported_lost
    kept = row("/Users/alex/projects/turf-monster/.worktrees/_ship", "removed 2026-08-19")
    dropped = row(SHIP, "removed 2026-08-20")

    lost = LedgerGuard.lost(base: [HEADER, HEADER + kept + dropped], head: [HEADER, HEADER + kept])

    assert_equal [SHIP], lost.map(&:path)
  end

  # COUNTED, NOT DEDUPED. Two teardowns of one path on ONE day are two episodes with the
  # same identity — the fixed writer appends both. A set-based comparison would see "the
  # identity is still present" and wave through the deletion of one of them.
  def test_unit_two_same_day_teardowns_of_one_path_are_counted_not_deduped
    both = row(SHIP, "removed 2026-08-21", reason: "first") + row(SHIP, "removed 2026-08-21", reason: "second")
    base = HEADER + both
    head = HEADER + row(SHIP, "removed 2026-08-21", reason: "first")

    lost = LedgerGuard.lost(base: [base], head: [head])

    assert_equal 1, lost.size, "one of the two same-day episodes was destroyed"
    assert_equal 1, lost.first.missing
  end

  # THE IDENTITY IS (path, status), NOT the whole line — stated here because it is a
  # deliberate tolerance, not an oversight. A docs sweep that rewords the "why" or
  # "condition" cell has not destroyed a teardown episode, and a guard that went red over
  # prose would be a false-positive machine pointed at the people maintaining the docs.
  # What it may NEVER tolerate is a changed DATE: that is a different episode wearing the
  # first one's row, which is the bug itself.
  def test_unit_the_episode_identity_is_the_path_and_the_status_cell
    base = HEADER + row(SHIP, "removed 2026-08-20", reason: "original wording")

    reworded = HEADER + row(SHIP, "removed 2026-08-20", reason: "clearer wording", condition: "Removed with the sweep.")
    assert_empty LedgerGuard.lost(base: [base], head: [reworded]),
                 "rewording a cell is a docs edit, not a destroyed episode"

    redated = HEADER + row(SHIP, "removed 2026-08-21", reason: "original wording")
    assert_equal 1, LedgerGuard.lost(base: [base], head: [redated]).size,
                 "a changed DATE is a DIFFERENT teardown standing where the first one was — " \
                 "the exact shape of the 2026-08-21 loss"
  end

  # A row whose Status carries no date is not history and is never tracked, wherever it
  # sits. Both long-lived `reference only` rows at the top of the live ledger are of this
  # kind, and the operator edits them freely.
  def test_unit_undated_rows_are_not_tracked_at_all
    base = HEADER + row("/Users/alex/.claude/agents/*.md", "reference only")

    assert_empty LedgerGuard.lost(base: [base], head: [HEADER]),
                 "an undated row is an open item; the guard bounds HISTORY, not the backlog"
  end

  # ================================================================================
  # [integration] the CLI, against a real git repo, driven by a STALE writer
  # ================================================================================

  def with_repo
    Dir.mktmpdir("ledger-guard") do |repo|
      system("git", "init", "--quiet", "-b", "main", repo, exception: true)
      system("git", "-C", repo, "config", "user.email", "test@example.com", exception: true)
      system("git", "-C", repo, "config", "user.name", "Test", exception: true)
      FileUtils.mkdir_p(File.join(repo, File.dirname(LedgerGuard::LEDGER)))
      FileUtils.mkdir_p(File.join(repo, File.dirname(LedgerGuard::ARCHIVE)))
      yield repo
    end
  end

  def ledger_file(repo) = File.join(repo, LedgerGuard::LEDGER)
  def archive_file(repo) = File.join(repo, LedgerGuard::ARCHIVE)

  def commit(repo, message = "fixture")
    system("git", "-C", repo, "add", "-A", exception: true)
    system("git", "-C", repo, "commit", "--quiet", "-m", message, exception: true)
  end

  def guard(repo, *args)
    out, err, status = Open3.capture3("ruby", CLI, "--repo=#{repo}", *args)
    { out: "#{out}#{err}", ok: status.success? }
  end

  # THE PRE-FIX WRITER, transcribed from 269e2db4's parent: it rewrote EVERY line
  # containing the path cell, dated or not. This is the code 12 of 18 hub worktrees were
  # still running, and it is the thing the guard must catch WITHOUT being able to change it.
  def stale_writer_write(path, new_row)
    existing = File.read(path)
    path_cell = new_row.split("`")[1].to_s
    if existing.include?(path_cell)
      File.write(path, existing.lines.map { |line| line.include?(path_cell) ? new_row : line }.join)
    else
      File.write(path, existing + new_row)
    end
  end

  # THE STALE-DESK REGRESSION. Nothing here runs the FIXED writer — the corruption is
  # produced by the old logic, exactly as a stale desk would produce it. The guard is not
  # in that process and does not need to be.
  def test_integration_a_stale_writer_clobbering_a_dated_row_turns_the_guard_red
    with_repo do |repo|
      File.write(ledger_file(repo), HEADER + row(SHIP, "removed 2026-08-20", reason: "HEAD d7ccca8d"))
      File.write(archive_file(repo), HEADER)
      commit(repo, "ledger with the 08-20 teardown")

      stale_writer_write(ledger_file(repo), row(SHIP, "removed 2026-08-21", reason: "HEAD be798149"))

      result = guard(repo, "--base=HEAD")

      refute result[:ok], "a destroyed resolved row must fail the guard, not merely warn"
      assert_includes result[:out], SHIP, "the report must name the path that lost a row"
      assert_includes result[:out], "removed 2026-08-20", "…and the episode that was destroyed"
      assert_includes result[:out], "d7ccca8d", "…and the row text, so recovery is a paste"
    end
  end

  # THE CONTROL, and it is load-bearing: a guard that is red for everything proves nothing
  # about the run above. Same repo, same recycled path, same second teardown — appended
  # the way the FIXED writer appends it — and the guard is green.
  def test_integration_the_same_second_teardown_appended_is_green
    with_repo do |repo|
      File.write(ledger_file(repo), HEADER + row(SHIP, "removed 2026-08-20", reason: "HEAD d7ccca8d"))
      File.write(archive_file(repo), HEADER)
      commit(repo, "ledger with the 08-20 teardown")

      File.write(ledger_file(repo), File.read(ledger_file(repo)) + row(SHIP, "removed 2026-08-21"))

      result = guard(repo, "--base=HEAD")

      assert result[:ok], "appending beside the predecessor is the invariant KEPT:\n#{result[:out]}"
    end
  end

  # The roll, end to end through git: rows leave the ledger and land in the archive. The
  # ledger alone SHRANK by every rolled row, so a guard that read one file would call this
  # a catastrophe. Reading the union is what makes the sanctioned move invisible to it.
  def test_integration_an_archive_roll_is_green_even_though_the_ledger_shrank
    with_repo do |repo|
      rolled = row(SHIP, "removed 2026-06-13") + row("/Users/alex/projects/turf-monster/.worktrees/_ship", "removed 2026-06-13")
      File.write(ledger_file(repo), HEADER + rolled + row(SHIP, "removed 2026-08-21"))
      File.write(archive_file(repo), HEADER)
      commit(repo, "ledger before the roll")

      File.write(ledger_file(repo), HEADER + row(SHIP, "removed 2026-08-21"))
      File.write(archive_file(repo), HEADER + rolled)

      result = guard(repo, "--base=HEAD")

      assert result[:ok], "a roll MOVES rows; the union is unchanged:\n#{result[:out]}"
    end
  end

  # A guard that cannot read its baseline must be RED, never green and never silent. The
  # whole point is a comparison against something OUTSIDE the working tree; "I could not
  # look" is not a pass.
  def test_integration_an_unreadable_base_is_red_not_green
    with_repo do |repo|
      File.write(ledger_file(repo), HEADER)
      File.write(archive_file(repo), HEADER)
      commit(repo)

      result = guard(repo, "--base=origin/does-not-exist")

      refute result[:ok], "an unresolvable base ref must fail the guard"
      assert_includes result[:out], "does-not-exist"
    end
  end

  # ================================================================================
  # [integration] the writer's own belt — prevention at the source, for fresh desks
  # ================================================================================

  # bin/agent-worktree now verifies its OWN ledger write and rolls it back rather than
  # leaving a destroyed row behind. Driven here through the REAL script with the pre-fix
  # selection helper redefined — i.e. the script IS the stale writer for the length of
  # this check — so the assertion is about the belt, not about the already-fixed selector.
  def test_integration_the_writer_refuses_and_reverts_its_own_destructive_write
    Dir.mktmpdir("ledger-writer") do |root|
      ledger = File.join(root, "delete-later.md")
      File.write(ledger, HEADER + row(SHIP, "removed 2026-08-20", reason: "HEAD d7ccca8d"))

      script = File.join(ROOT, "bin", "agent-worktree")
      body = <<~RUBY
        load #{script.inspect}
        def ledger_path; #{ledger.inspect}; end
        def reclaim_evidence(_record, **_kw)
          { free: true, hold: nil, rationale: "merged into origin/accepted, tree clean" }
        end
        # THE STALE SELECTOR: the pre-269e2db4 rule — any row for this path, dated or not.
        def open_ledger_row_index(lines, dir)
          lines.index { |line| line.include?("`\#{dir}` |") }
        end
        record = { app: { "slug" => "mcritchie-studio" }, task: "_ship", dir: #{SHIP.inspect},
                   branch: "release", head: "be798149", merged: true, base_ref: "origin/accepted",
                   redis_db: "24", db_name: "hub_ship", db_exists: true,
                   env_exists: true, code: "000", port_pid: "" }
        begin
          write_cleanup_ledger_record(record, status: "removed 2026-08-21")
        rescue SystemExit, StandardError => e
          puts "REFUSED: \#{e.class}"
        end
      RUBY

      out, err, = Open3.capture3({ "MCRITCHIE_SESSION_ID" => "", "CLAUDE_SESSION_ID" => "" },
                                 "ruby", "-e", body)
      after = File.read(ledger)

      assert_includes "#{out}#{err}", "REFUSED",
                      "the writer must ABORT on a destructive write, not print a success line"
      assert_includes after, "removed 2026-08-20",
                      "…and it must leave the predecessor row exactly where it found it"
      assert_includes after, "d7ccca8d"
    end
  end

  # ================================================================================
  # [integration] THE LIVE GATE — this repository's own ledger, in CI
  # ================================================================================

  # This is the check that actually protects the ledger. Everything above proves the
  # instrument works; this one points it at the real file, on every PR and every push to a
  # shippable tip, from a checkout that is by definition NOT the desk that wrote the row.
  def test_integration_this_repo_never_loses_a_resolved_ledger_row
    bases = BASE_REFS.filter_map { |ref| LedgerGuard.merge_base(ROOT, ref) && ref }

    refute_empty bases,
                 "THE GUARD CANNOT SEE A BASELINE, so it certifies nothing. None of " \
                 "#{BASE_REFS.join(', ')} resolves in #{ROOT}. This is RED ON PURPOSE: the " \
                 "invariant is a comparison against history OUTSIDE this working tree, and a " \
                 "guard that passed when it could not read that history would be a green " \
                 "light with nothing behind it. Run `git fetch origin accepted` and retry. " \
                 "(CI has it: the `rails` lane checks out with fetch-depth: 0.)"

    # Reported ONCE per destroyed row, with the refs that still hold it — the same row is
    # normally visible from all three bases, and printing it three times buries the one
    # thing the reader needs: the row text to paste back.
    seen = bases.each_with_object({}) do |ref, tally|
      LedgerGuard.lost_against_ref(ROOT, ref).each { |episode| (tally[episode.line] ||= []) << ref }
    end
    lost = seen.map { |line, refs| "  #{line}\n    still recorded at: #{refs.join(', ')}" }

    assert_empty lost, <<~MSG
      THE DELETE-LATER LEDGER LOST RESOLVED ROWS. Each line below is a teardown that is
      recorded in this repo's history and is now in NEITHER #{LedgerGuard::LEDGER} nor
      #{LedgerGuard::ARCHIVE}:

      #{lost.join("\n")}

      Rows are MOVED to the archive, never deleted. The usual cause is a teardown driven
      from a desk carrying a stale bin/agent-worktree, which overwrites a dated row in
      place. Each row is still readable at the ref beside it, so recovery is a paste:

        git show <ref>:#{LedgerGuard::LEDGER}
        git show <ref>:#{LedgerGuard::ARCHIVE}

      Put the row back where it belongs — in the ledger if its date is newer than the last
      rollover, in the archive otherwise. Do not resolve this by editing the guard.
    MSG
  end
end
