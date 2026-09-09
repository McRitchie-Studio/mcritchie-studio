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
#   * test_satellite_checkouts_carry_no_fast_lane_scripts — the other half of the fact,
#     read off disk. If a satellite ever grows a `bin/ship` shim (option (b) in the PR
#     body), this goes red and the docs above must be revisited rather than silently
#     becoming over-strict.
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
# that the command it prints exists. (3) The satellite half needs the sibling checkouts
# on disk and skips without them, so on CI the guard rests on the first three tests.
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

  # --- the other half of the fact, read off disk ---------------------------------
  test "satellite checkouts carry no fast lane scripts" do
    projects = Rails.root.to_s.include?("/.worktrees/") ? Rails.root.join("../../..") : Rails.root.join("..")
    projects = projects.cleanpath
    siblings = %w[turf-monster rolio mcritchie-industries studio-engine solana-studio]
               .map { |slug| [slug, projects.join(slug)] }
               .select { |(_slug, path)| path.directory? }
    skip "no sibling checkouts under #{projects} — this half needs the machine" if siblings.empty?

    siblings.each do |(slug, path)|
      FAST_LANE.each do |cmd|
        refute path.join("bin", cmd).exist?,
               "#{slug} now carries bin/#{cmd}. The fast-lane docs say a satellite has " \
               "none and must be invoked hub-absolute — revisit them before this shim lands."
      end
    end
  end
end
