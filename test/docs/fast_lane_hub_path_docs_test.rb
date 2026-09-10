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
#   * test_pasteable_fences_name_desk_run_commands_absolutely — the defect itself. A
#     fenced block a reader copies may not name a DESK-RUN command by the bare `bin/…`
#     form, because that form resolves only from a hub desk. EVERY fence is pasteable
#     unless it opts out — see "WHICH FENCES ARE PASTEABLE" below.
#   * test_the_docs_table_classifies_every_repo_it_names — the docs print a table saying
#     which repos can run the fast lane. The registry that decides it lives in THIS repo
#     (config/satellites.yml), so the table is checked against it on every run, CI
#     included: register a satellite, or retire one, and the table reddens until it
#     catches up. BOTH directions, and only since 2026-09-09 — see the completeness
#     assertion inside that test for what the subset checks alone could not see.
#   * test_no_satellite_checkout_carries_a_fast_lane_script — the same fact read off
#     disk. If a satellite ever grows a `bin/ship` shim (option (b) in the PR body),
#     this goes red and the table must be revisited rather than silently going stale.
#     It inspects whatever sibling checkouts exist and is deliberately NOT the only
#     assertion in its file — see the note above that test for why it carries no skip.
#
# WHY "DESK-RUN" IS THE SCOPE AND NOT "EVERY FAST-LANE COMMAND". The path is only half
# the instruction; the cwd is the other half, and they answer different questions — the
# path picks the SCRIPT, the cwd picks the TREE it acts on. THE TWO WRITERS DIFFER ON
# WHAT A WRONG CWD COSTS, and conflating them is a real defect this file shipped once:
#
#   * THE CERT WRITERS REFUSE. bin/fast-check and bin/full-suite-check root at the cwd's
#     git toplevel and take CertRootGuard#refusal — the only two callers of it — so from
#     the hub against a satellite task they exit 1: "this run roots at
#     …/mcritchie-studio (branch main), which is not <slug>'s tree — refusing to certify
#     it."
#   * bin/ship RE-ROOTS, LOUDLY. It reads CertRootGuard.assess directly because it wants
#     :resolved_root, prints "re-rooting at the task worktree <desk> (you ran from
#     <cwd>)" and carries on there; it die!s only when resolved_root is nil (no desk on
#     disk, or a multi-repo tie). Its own comment says so: ship "re-roots rather than
#     refuses when the task's worktree exists on disk — loudly". The first draft of this
#     header attached the cert writers' verbatim refusal to bin/ship, which is the
#     highest-credibility claim form in this house pointed at the wrong command.
#
# Either way a `cd <hub>` earlier in the block does NOT excuse a bare form for any
# DESK_RUN command: for a desk-run command, standing in the hub is at best a re-root and at worst a
# refusal. The HUB-RUN commands (`bin/task begin`, `bin/agent-worktree`) are correctly
# reachable after a `cd <hub>` and are deliberately left out — which is a load-bearing
# exemption, so an edit that leaves a reader standing in a DESK before a hub-run fence
# has to restore the `cd <hub>` by hand; this guard cannot see it.
#
# WHICH FENCES ARE PASTEABLE — CHECKED UNLESS EXCUSED (task guard-skips-copy-paste-fences).
# The first cut scanned ```bash fences only and called a ```text fence prose, admitting
# "no crisp classifier separates them". That keyed the guard on fence LANGUAGE when the
# property that matters is COPY-PASTEABILITY — and it regressed within one night:
# 3617fa35 (ms#1339) put a bare `bin/ship <task> -m` back into the "good prompt" ```text
# block, which exists to be pasted verbatim into a new session. Three rules were weighed:
#
#   * OPT-IN MARKER on pasteable blocks — rejected: it fails OPEN. A new pasteable block
#     that forgets the marker is unguarded, the same failure the bash-only rule had.
#   * LABEL CONVENTION ("A good prompt is:") — rejected as the classifier: it keys the
#     guard on its own prose, and a relabel silently switches it off. It is used below
#     only to LOCATE the good-prompt pin, where a missing label fails CLOSED.
#   * SCAN EVERY FENCE, EXCUSE BY MARKER — chosen: it fails CLOSED. A new fence of any
#     language is checked by default, and the only way out is visible at the site.
#
# THE CRISP RULE. Inside a fence that has not opted out, a guarded script is named
# hub-absolute EVERY time — instruction or description alike. That removes the per-line
# judgment the old header called impossible: nobody has to decide whether "runs
# bin/dor-check" is a command. A paste-reader cannot tell either, so neither does this.
#
# THE OPT-OUT is `not-pasteable` as the fence's WHOLE info string (```not-pasteable), on
# the OPENING LINE so no edit can separate the excuse from its block. Never a second
# word after a language: the in-app viewer (Redcarpet, /docs/*) then drops the fence and
# prints it as inline code, measured on review. Two floors keep it honest: an
# excused fence must actually contain a bare guarded path (a marker that excuses nothing
# is a silencer waiting to be copied), and the number of excused fences is capped in
# MAX_EXCUSED_FENCES, so adding one is a visible diff here too.
#
# ITS LIMITS, STATED PLAINLY. (1) PROSE outside any fence is not scanned — a sentence
# telling the reader to run a bare script is still possible, and those sites are owned by
# /tasks/entry-docs-bare-hub-commands. (2) Nothing here proves a corrected sentence is well WORDED — only
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
  # the bare `bin/…` form is wrong from every desk but the hub's. `ship-wait` is here
  # because it LAUNCHES bin/ship, so it inherits the cwd contract exactly: it lives only
  # in the hub, and the docs tell a builder to run it from the desk. It must precede
  # `ship` in this list — Regexp.union alternates in order, so a leading `ship` would
  # match the `ship` inside `bin/ship-wait` and report the wrong command in the remedy.
  #
  # `gh-auth-refresh` is here for the same reason from a different door: it is run from
  # WHEREVER the builder stands when a token lapses, and mid-ship that is the desk. It
  # lives only in the hub (no satellite carries it — the shim sweep below checks), and it
  # resolves its helper from its own __dir__, so the hub-absolute form works from any cwd.
  # It is usually wrapped — eval "$(bin/gh-auth-refresh --export)" — and BARE is not
  # anchored to the line start, so the wrapper does not hide it.
  DESK_RUN = %w[ship-wait ship fast-check full-suite-check dor-check gh-auth-refresh].freeze

  # The info-string token that excuses a fence from the pasteable scan. See the header.
  NOT_PASTEABLE = "not-pasteable"

  # Today exactly one fence is excused: the in-flight roster mock-up in the
  # communication-style section, which illustrates chat OUTPUT (`bin/ship restyle-…`
  # beside meter glyphs), not a command. Raising this number is a decision, not a fix.
  MAX_EXCUSED_FENCES = 1

  # The label the good-prompt template sits under — used ONLY to locate the pin below.
  GOOD_PROMPT_LABEL = "A good prompt is:"

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
  # HENCE THE HOUSE RULE FOR THIS FILE: write `config/<name>` ONLY for a config this
  # file actually reads — today that is satellites.yml and nothing else. Every other
  # config is named by BARE BASENAME (test_health.yml, rails_lane.yml), which stays
  # navigable for a reader while matching neither grep token: the mapper looks for the
  # full path, or for the basename IN QUOTES. Expanding one of those back into a full
  # path is not a tidy-up — it invents a dependency this file does not have, and can
  # push that config over the cap.
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

  Fence = Struct.new(:opened_at, :lang, :tokens, :lines, keyword_init: true) do
    def excused? = lang == NOT_PASTEABLE
  end

  # Every fence in `body`, whatever its language, with its info string split into the
  # language (first word) and the remaining tokens. `lines` is [[line_number, line], …].
  def fences(body)
    found = []
    current = nil
    body.each_line.with_index(1) do |line, number|
      # lstrip FIRST. A fence indented inside a list item is still a fence, and matching
      # on the raw line silently left every such block unparsed — the scan would sail
      # past an indented fence without ever entering it, so a bare `bin/ship` there was
      # unpinned. Measured on review, 2026-09-09.
      if line.lstrip.start_with?("```")
        if current
          found << current
          current = nil
        else
          words = line.strip.delete_prefix("```").split
          current = Fence.new(opened_at: number, lang: words.first.to_s, tokens: words.drop(1), lines: [])
        end
        next
      end
      current&.lines&.push([number, line])
    end
    found
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
  test "pasteable fences name desk run commands absolutely" do
    offences = []
    DOCS.each do |rel|
      pasteable = fences(read_doc(rel)).reject(&:excused?)

      # FLOOR — the widening is live. Each doc carries non-bash fences that must now be
      # scanned; if the scan ever narrows back to one language, this reddens first.
      refute_empty pasteable.reject { |f| f.lang == "bash" },
                   "#{rel}: no non-bash fence was scanned — the guard has narrowed back to " \
                   "fence LANGUAGE, which is the hole guard-skips-copy-paste-fences closed"
      assert_operator pasteable.sum { |f| f.lines.size }, :>, 0, "#{rel}: no fenced lines were parsed"

      pasteable.each do |fence|
        fence.lines.each do |(number, line)|
          line.scan(BARE) do |(cmd)|
            offences << "#{rel}:#{number} names bare `bin/#{cmd}` in a pasteable " \
                        "#{fence.lang.empty? ? 'bare' : fence.lang} fence (opened at line " \
                        "#{fence.opened_at}). It resolves only from a hub desk — name " \
                        "#{HUB_PREFIX}/bin/#{cmd}, or reword a description so it names no path. " \
                        "If the block illustrates OUTPUT rather than something to paste, mark it " \
                        "```#{NOT_PASTEABLE} and raise MAX_EXCUSED_FENCES."
          end
        end
      end
    end
    assert_empty offences, offences.join("\n")
  end

  # --- the opt-out may not become a silencer --------------------------------------
  test "every excused fence is load bearing and the count is capped" do
    excused = DOCS.flat_map do |rel|
      fences(read_doc(rel)).select(&:excused?).map { |f| [rel, f] }
    end

    excused.each do |(rel, fence)|
      assert fence.lines.any? { |(_, line)| line.match?(BARE) },
             "#{rel}:#{fence.opened_at} is marked #{NOT_PASTEABLE} but names no bare guarded " \
             "path — the marker excuses nothing. Remove it; an idle excuse is a silencer."
    end
    assert_operator excused.size, :<=, MAX_EXCUSED_FENCES,
                    "#{excused.size} fences are marked #{NOT_PASTEABLE}, over the cap of " \
                    "#{MAX_EXCUSED_FENCES}: #{excused.map { |(rel, f)| "#{rel}:#{f.opened_at}" }.join(', ')}"
    # Non-vacuity: the marker parser must actually find the one known excuse.
    assert_operator excused.size, :>=, 1, "no #{NOT_PASTEABLE} fence found — the info-string parser is broken"
  end

  # The in-app viewer (app/controllers/docs_controller.rb, Redcarpet) drops a fence whose
  # info string has a second word; ```text not-pasteable did that to /docs/index.
  test "the in app docs viewer renders every parsed fence" do
    DOCS.each do |rel|
      body = read_doc(rel)
      shown = DocsController.new.send(:render_markdown, body).scan("<pre>").size
      assert_equal fences(body).size, shown, "#{rel}: this guard parsed #{fences(body).size} fences; /docs renders #{shown}"
    end
  end

  # --- the template that regressed is pinned by name --------------------------------
  # Criterion 3. The good prompt is pasted verbatim into new sessions, so it must be
  # SCANNED (never excused) and must carry the hub-absolute ship. Located by its label;
  # a relabel fails CLOSED here rather than quietly dropping the pin.
  test "the good prompt template is scanned and names ship absolutely" do
    body = read_doc("docs/agents/index.md")
    # end_with?, not ==: the label closes a wrapped prose line ("…and the feature. A good
    # prompt is:"), and the fence opens two lines below it.
    label_at = body.lines.index { |line| line.rstrip.end_with?(GOOD_PROMPT_LABEL) }
    refute_nil label_at, "docs/agents/index.md lost the line #{GOOD_PROMPT_LABEL.inspect} — " \
                         "re-point GOOD_PROMPT_LABEL so the template stays pinned"

    template = fences(body).find { |f| f.opened_at > label_at + 1 }
    refute_nil template, "no fence follows #{GOOD_PROMPT_LABEL.inspect}"
    refute template.excused?, "the good-prompt template is marked #{NOT_PASTEABLE} — it exists " \
                              "to be pasted, so it may never be excused"
    text = template.lines.map(&:last).join
    assert_includes text, "#{HUB_PREFIX}/bin/ship",
                    "the good-prompt template no longer names #{HUB_PREFIX}/bin/ship"
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
  # test_health.yml's EXACT skip call-site count went 25 → 26 by reading the source,
  # and rails_lane.yml's executed-skip ceiling went 11 → 12 at RUNTIME.
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

      # COMPLETENESS — the direction every check above is blind to, because each one only
      # asks whether a slug the table ALREADY names is classified right. Measured both
      # ways on 2026-09-09: dropping turf-monster from config/satellites.yml reddens (its
      # slug is left in the table naming a repo the registry no longer manages), but
      # ADDING a satellite stayed green forever. That is also why tax-studio and
      # chain-ops sat un-named in this table with nothing complaining. The header claimed
      # both directions bite; this is the assertion that makes the claim true.
      #
      # A REGISTERED-BUT-UNBUILT app still belongs in the row. The rule the table states
      # is about where the fast-lane SCRIPTS live, not about what is checked out — it
      # holds the day the repo lands, and listing it early is how the doc stops lagging
      # the registry.
      missing = (managed - ["mcritchie-studio"]) - satellite_row
      assert_empty missing,
                   "#{rel}: config/satellites.yml registers #{missing.join(', ')}, which the " \
                   "fast-lane desk table never names. Add them to the satellite row."
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
