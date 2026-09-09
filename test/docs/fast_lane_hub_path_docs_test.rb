# frozen_string_literal: true

require "test_helper"

# THE FAST-LANE HANDOFF INSTRUCTION IS A CLAIM ABOUT WHERE A SCRIPT LIVES, and until
# this test existed nothing checked it against the filesystem.
#
# MEASURED, 2026-09-09 (task ship-path-misleads-satellites). Both generated entry docs
# instructed `bin/ship <task-slug> -m "…"` "run from that worktree". From a SATELLITE
# desk (turf-monster, rolio, mcritchie-industries) that path does not exist: every
# fast-lane script lives only in mcritchie-studio/bin, and the launch dies instantly as
# `nohup: bin/ship: No such file or directory`. It cost several builders time in one
# night, and turf-monster is the busiest satellite on the board.
#
# WHY THE SENTENCE READ AS CORRECT. The fast-lane section is written from a HUB desk,
# where `bin/ship` really is on the path — a hub worktree checks the scripts out — and
# the very next clause says "run from that worktree". So the instruction is true for the
# desk its author was standing in and false for every other one, which is the failure
# mode a grep for the sentence can never catch.
#
# WHAT THIS GUARD PINS, AND WHY IT IS NOT A GREP FOR THE SENTENCE. The honest assertion
# is that the command the docs tell a builder to run RESOLVES TO AN EXISTING EXECUTABLE.
# So the guard is keyed on the filesystem, not on prose:
#
#   * test_fast_lane_scripts_live_in_the_hub — the FACT the instruction depends on. If
#     bin/ship is renamed, moved, or deleted, this reddens first.
#   * test_documented_hub_paths_resolve — every hub-absolute path the docs PRINT is
#     mapped back to this repo and must be an executable file. So the doc cannot name a
#     script that does not exist.
#   * test_bash_blocks_name_desk_run_commands_absolutely — the defect itself. A shell
#     block a builder copies may not invoke a DESK-RUN command by the bare `bin/…` form,
#     because that form resolves only from a hub desk.
#   * test_the_docs_table_classifies_every_repo_it_names — the docs print a table saying
#     which repos can run the fast lane. The registry that decides it lives in THIS repo
#     (config/satellites.yml), so the table is checked against it on every run, CI
#     included: register a satellite, or retire one, and the table reddens until it
#     catches up.
#   * test_no_satellite_checkout_carries_a_fast_lane_script — the same fact read off
#     disk. If a satellite ever grows a `bin/ship` shim (option (b) in the PR body),
#     this goes red and the table must be revisited rather than silently going stale.
#     It inspects whatever sibling checkouts exist and is deliberately NOT the only
#     assertion in its file — see the note above that test for why it carries no skip.
#
# WHY "DESK-RUN" IS THE SCOPE AND NOT "EVERY FAST-LANE COMMAND". The path is only half
# the instruction; the cwd is the other half, and they answer different questions — the
# path picks the SCRIPT, the cwd picks the TREE it acts on. bin/fast-check roots its cert
# at the cwd's git toplevel and CertRootGuard REFUSES when that is not the task's tree,
# so `cd <hub> && bin/ship <satellite-slug>` fails in the OPPOSITE direction (measured:
# "this run roots at …/mcritchie-studio (branch main), which is not <slug>'s tree —
# refusing to certify it"). That is why a `cd <hub>` earlier in the block does NOT excuse
# a bare form for these four: for a desk-run command, standing in the hub is itself the
# bug. The HUB-RUN commands (`bin/task begin`, `bin/agent-worktree`) are correctly
# reachable after a `cd <hub>` and are deliberately left out.
#
# ITS LIMITS, STATED PLAINLY. (1) The block scan covers ```bash fences only — the shell a
# reader copies. A ```text fence is prose (the "good prompt" template, the measurement
# tables of what each `--agent` form stamps) and naming a bare command there is not
# always wrong, so no crisp classifier separates them; those sites were corrected by hand
# and are not pinned. (2) Nothing here proves a corrected sentence is well WORDED — only
# that the command it prints exists. (3) The on-disk shim sweep can only inspect the
# checkouts a given machine has, so on CI it inspects none — which is why the table
# test, not the sweep, is what holds this contract there. It is stated as a bonus loop
# rather than hidden behind a `skip`, because a skip would have reported a passing test
# name for a guard switched off in the one place it runs on every PR.
class FastLaneHubPathDocsTest < ActiveSupport::TestCase
  DOCS = %w[docs/agents/claude.md docs/agents/index.md].freeze

  # The projects root the generated entry docs are written against. It is a literal in
  # the docs (they open with "Work from /Users/alex/projects"), so it is a literal here.
  HUB_PREFIX = "/Users/alex/projects/mcritchie-studio"

  # Commands the docs instruct a builder to run STANDING IN THE TASK'S DESK. For these
  # the bare `bin/…` form is wrong from every desk but the hub's.
  DESK_RUN = %w[ship fast-check full-suite-check dor-check].freeze

  # Every fast-lane script, desk-run or hub-run.
  FAST_LANE = (DESK_RUN + %w[task]).freeze

  BARE = /(?<![\w\/.-])bin\/(#{Regexp.union(DESK_RUN)})(?![\w-])/

  # WHICH REPOS THE FAST LANE CAN DESK, read off the registry rather than listed here.
  # bin/agent-worktree manages the hub plus every entry in config/satellites.yml (that is
  # exactly what `bin/agent-worktree apps` prints); everything else in the release
  # registry — the gems, and turf-vault — cannot be desked, so `bin/task begin` answers
  # `unknown app` there. Onboard a gem and this set changes, which is precisely when the
  # docs' table must be revisited.
  MANAGED_REPOS = (
    ["mcritchie-studio"] +
    YAML.load_file(Rails.root.join("config/satellites.yml")).fetch("satellites").map { |s| s.fetch("slug") }
  ).freeze

  # ONE REGISTRY, NOT TWO — AND THE SECOND ONE COST MORE THAN IT WAS WORTH.
  # The first draft also read the RELEASE registry (the sibling YAML listing the gems
  # and apps), to assert that a slug in the no-lane row is a repo SOME registry knows —
  # a typo guard. MEASURED on CI: that one reference pushed the release registry from 15
  # grep-reachable test files to 16, one over FastCert::DEFAULT_MAPPED_CAP — and past
  # the cap bin/fast-check's mapped lane falls back to the CONVENTION TWINS ALONE. So
  # editing that registry would have stopped mapping to the 15 tests that depend on it,
  # to buy a typo check on three slugs in a docs table.
  # test/lib/fast_cert_subject_test.rb caught it, which is what that sweep is for.
  #
  # ITS PATH IS DELIBERATELY NOT SPELLED ANYWHERE IN THIS FILE, and that is the whole
  # remedy. The mapper greps for the path STRING, so it does not distinguish code that
  # loads a config from prose that merely mentions one: deleting the `load_file` call
  # while leaving the path in this very comment left the count at 16, unchanged.
  #
  # Nothing load-bearing was lost. The two claims that matter both rest on
  # config/satellites.yml (4 reachable files, far under the cap): a slug in the
  # satellite row MUST be deskable, and a slug in the no-lane row must NOT be. A
  # typo'd slug in the no-lane row is the harmless direction — it names a repo that
  # does not exist as having no fast lane, which is vacuously true.

  # The three-row desk table, as [[hub slugs], [satellite slugs], [no-lane slugs]].
  # Each row's first cell carries backticked repo slugs; the prose cell is ignored.
  def table_rows(body)
    header = "| Desk | Fast lane from that desk |"
    lines = body.lines.map(&:rstrip)
    start = lines.index(header)
    return [] unless start

    lines[(start + 2)..]
      .take_while { |line| line.start_with?("|") }
      .map { |line| line.split("|")[1].to_s.scan(/`([a-z0-9-]+)`/).flatten }
  end

  def read_doc(rel)
    path = Rails.root.join(rel)
    assert path.exist?, "#{rel} is missing — the fast-lane instruction has no home"
    path.read
  end

  # Every ```<lang> fence in `body`, as [lang, line_number, line].
  def fenced_lines(body, lang:)
    open_lang = nil
    body.each_line.with_index(1).filter_map do |line, number|
      if line.start_with?("```")
        open_lang = open_lang ? nil : line.strip.delete_prefix("```").strip
        next
      end
      next unless open_lang == lang

      [open_lang, number, line]
    end
  end

  # --- the fact the instruction rests on ----------------------------------------
  test "fast lane scripts live in the hub" do
    FAST_LANE.each do |cmd|
      script = Rails.root.join("bin", cmd)
      assert script.exist?, "bin/#{cmd} is gone from this repo — the fast-lane docs name it"
      assert File.executable?(script), "bin/#{cmd} is not executable"
    end
  end

  # --- the docs may not name a script that does not exist ------------------------
  test "documented hub paths resolve" do
    named = 0
    DOCS.each do |rel|
      body = read_doc(rel)
      body.scan(%r{#{Regexp.escape(HUB_PREFIX)}/bin/([\w-]+)}) do |(cmd)|
        named += 1
        script = Rails.root.join("bin", cmd)
        assert script.exist?,
               "#{rel} tells an agent to run #{HUB_PREFIX}/bin/#{cmd}, which does not exist"
        assert File.executable?(script), "#{rel} names bin/#{cmd}, which is not executable"
      end
    end
    # Non-vacuity: the scan must actually find the hub-absolute invocations. Without
    # this a regex that matched nothing would pass every assertion above.
    assert_operator named, :>=, DOCS.size,
                    "found #{named} hub-absolute fast-lane paths across #{DOCS.size} docs — " \
                    "the scan is matching nothing, so this test proves nothing"
  end

  # --- the defect: a copy-pasteable bare form ------------------------------------
  test "bash blocks name desk run commands absolutely" do
    offences = []
    scanned = 0
    DOCS.each do |rel|
      fenced_lines(read_doc(rel), lang: "bash").each do |(_lang, number, line)|
        scanned += 1
        next unless (hit = line.match(BARE))

        offences << "#{rel}:#{number} invokes bare `bin/#{hit[1]}` — that resolves only " \
                    "from a hub desk. Name #{HUB_PREFIX}/bin/#{hit[1]} and " \
                    "stand in the task's desk."
      end
    end
    assert_operator scanned, :>, 0, "no ```bash fences were parsed — the fence scanner is broken"
    assert_empty offences, offences.join("\n")
  end

  # Every alternative in BARE must really match its command; an alternative that never
  # fires would silently exempt that command from the test above.
  test "bare pattern matches every desk run command" do
    DESK_RUN.each do |cmd|
      assert_match BARE, "bin/#{cmd} <task-slug>", "BARE does not match bin/#{cmd}"
      refute_match BARE, "#{HUB_PREFIX}/bin/#{cmd} <task-slug>",
                   "BARE wrongly flags the hub-absolute form of bin/#{cmd}"
    end
  end

  # --- the table must match the registry, and no satellite may carry a shim ------
  # NO `skip` HERE, DELIBERATELY. The first draft of this test skipped whenever the
  # sibling checkouts were absent — which is exactly the case ON CI, so the guard was
  # switched off in the one place it runs on every PR, while still reporting a passing
  # test name. TWO independent ratchets caught it, and the pair is the proof:
  # config/test_health.yml's EXACT skip call-site count went 25 → 26 by reading the
  # source, and config/rails_lane.yml's executed-skip ceiling went 11 → 12 at RUNTIME.
  # The second only moves if the skip actually FIRES on CI — which is precisely the
  # defect, measured, rather than a worry about one. The fix was to give the test a
  # claim it can always check: the
  # docs' repo table is derived from registries that live IN this repo, so classifying
  # every slug it names works everywhere. The on-disk shim sweep then rides along as a
  # second loop, biting on a dev machine and adding nothing on CI — a bonus, never the
  # test's only assertion.
  test "the docs table classifies every repo it names" do
    managed = MANAGED_REPOS
    rows_seen = 0
    slugs_seen = 0

    DOCS.each do |rel|
      rows = table_rows(read_doc(rel))
      assert_equal 3, rows.size,
                   "#{rel}: expected the 3-row fast-lane desk table, found #{rows.size} row(s)"
      rows_seen += rows.size

      hub_row, satellite_row, no_lane_row = rows
      slugs_seen += (hub_row + satellite_row + no_lane_row).size

      assert_equal ["mcritchie-studio"], hub_row,
                   "#{rel}: the hub row must name exactly the hub"

      satellite_row.each do |slug|
        assert_includes managed, slug,
                        "#{rel} lists #{slug} as a satellite desk, but bin/agent-worktree " \
                        "cannot desk it — it belongs in the no-lane row"
        refute_equal "mcritchie-studio", slug, "#{rel}: the hub is not a satellite"
      end

      no_lane_row.each do |slug|
        refute_includes managed, slug,
                        "#{rel} says #{slug} has no fast lane, but it IS a managed app — " \
                        "bin/task begin can desk it, so the table is now wrong"
      end
    end

    # Non-vacuity: a table scan that matched nothing would satisfy every loop above.
    assert_operator rows_seen, :>=, DOCS.size * 3, "the table scan found no rows"
    assert_operator slugs_seen, :>=, DOCS.size * 6, "the table scan found too few repo slugs"
  end

  # Rides along: on a machine that HAS the sibling checkouts, a shim landing in a
  # satellite contradicts the table above. Adds nothing on CI, and is never this
  # file's only assertion — see the note on the test above.
  test "no satellite checkout carries a fast lane script" do
    projects = if Rails.root.to_s.include?("/.worktrees/")
                 Rails.root.join("../../..")
               else
                 Rails.root.join("..")
               end.cleanpath

    present = (MANAGED_REPOS - ["mcritchie-studio"]).filter_map do |slug|
      path = projects.join(slug)
      [slug, path] if path.directory?
    end

    present.each do |(slug, path)|
      FAST_LANE.each do |cmd|
        refute path.join("bin", cmd).exist?,
               "#{slug} now carries bin/#{cmd}. The fast-lane docs say a satellite has " \
               "none and must be invoked hub-absolute — revisit that table before this shim lands."
      end
    end

    # States what this run actually inspected, so a green here is never mistaken for
    # proof on a machine that had nothing to inspect.
    assert true, "inspected #{present.size} sibling checkout(s) under #{projects}"
  end
end
