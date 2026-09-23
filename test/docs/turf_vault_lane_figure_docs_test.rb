# frozen_string_literal: true

require "test_helper"
require_relative "../support/stated_prose"

# GUARD (turf-vault-lane-figure, 2026-09-22): a hub source that states a MEASURED
# FIGURE about turf-vault's `bin/release-check` must carry, in the same paragraph,
# something that RE-DERIVES it — the command that prints it, or the SHA it was
# measured at. A bare count is stale by default.
#
# WHAT HAPPENED. docs/agents/claude.md (which installs as the projects-root
# CLAUDE.md, auto-loaded before every agent session takes its first action) said
# turf-vault's `bin/release-check` runs "that repo's four CI lanes, ~1s warm, 61
# `node:test` cases among them". Measured 2026-09-22 against `origin/accepted` at
# `09cdfb3`, every figure in that clause was wrong or incomplete:
#
#   claimed              measured                      how it rotted
#   four CI lanes        FIVE (2 Node + 3 Rust)        `cargo test` joined 2026-09-15
#   61 `node:test` cases 171                           the suite grew; nobody re-read it
#   ~1s warm             76s COLD / 1-2s on a re-run   only the flattering half was quoted
#   (Rust unmentioned)   60 Rust tests                 a whole lane family was invisible
#
# THE COST. This is the passage that tells agents never to record a "no tests" skip
# for turf-vault, because it HAS a suite and HAS a lane. The conclusion was right
# and every figure supporting it was wrong — so a builder budgeting a cert against
# "~1s warm" watches a 76s lane and concludes the gate has hung, on the authority of
# the first file their session reads.
#
# WHY A PROVENANCE PROPERTY AND NOT A RATCHET. Banning the strings "four CI lanes"
# and "61 cases" would catch only the two spellings already deleted; the suite will
# grow past 171 and the next figure will rot exactly the same way. The defect is not
# which number was written, it is that a number was written with no way to check it.
# So the guard demands the CHECK, and stays true at any count.
#
# A BARE `bin/release-check` IS NOT PROVENANCE. The stale sentence named the script
# — naming it is how the figure's SUBJECT is identified, not how its VALUE is
# derived. Only a command that PRINTS the figure counts (`--list` for the lane
# table, the two suite commands for their own totals), or a SHA that pins the tree.
# A measurement DATE does not count either, and that is deliberate:
# modules/gates/g1-cert.md carried "measured 2026-09-14 at ~1s warm" and rotted
# anyway, because a date says when someone looked, never at what or how.
#
# THE SECOND TEST guards a subtlety that a plain count erases. Of the 171 cases,
# three self-skip when `node_modules` is absent — CI's `guards` lane, and any fresh
# clone — via `try { require("@sqds/multisig") } catch { t.skip(); return; }`. The
# counters are honest there (`pass 168 / skipped 3`), but the TAP lines read
# `ok <n> … # SKIP`, which is pass-SHAPED: a scan for `not ok` sees nothing. So
# "171 cases pass" is true only with the deps installed, and a doc that states the
# count owes the condition.
#
# ── WHAT THE POPULATION FIX CHANGED (guard-lane-figures-beyond-docs, 2026-09-22) ──
#
# THE GLOB WAS THE HOLE. This guard shipped scanning `docs/**/*.md`, so it could not
# see the release-repo registry under `config/` — the file where the lane is DECLARED,
# which carried
# three of the four wrong figures and which the corrected claude.md routes readers
# straight at. It now reads the shared `StatedProse` population (markdown anywhere
# plus the comment bodies of config/app/lib/bin), the same population the preview
# guard reads, so the decision about what this house measures its authors against is
# made ONCE. Widening found three more live sites outside `docs/`: this file's own
# registry row, `bin/fast-check`, and the suite count on that same row.
#
# PROVENANCE IS PER PARAGRAPH, NOT PER FIGURE, and this comment says so because the
# code does. One PROVENANCE match unlocks EVERY figure in the block, so a paragraph
# can pair a wrong count with a command that prints a different number and pass. A
# per-figure property was considered and NOT implemented: the correct prose this
# guard already accepts states its figures several lines above the "re-derive these"
# sentence that backs them, so a per-figure proximity rule reddens the very text the
# guard exists to bless. A guard that cries wolf on its own fix gets muted. The
# paragraph is the unit that makes a claim, and it is the unit that owes one.
class TurfVaultLaneFigureDocsTest < ActiveSupport::TestCase
  # The repo the figure is about. Without this every "5 lanes" in the tree trips.
  SUBJECT = /turf-vault|release-check/i

  # The repo NAME alone. `release-check` is a script THREE repos own (studio-engine
  # and solana-studio declare one too, and `bin/fast-check` discusses all of them in
  # one breath), so it can identify the subject of a `node:test` figure — a toolchain
  # only turf-vault uses — but it cannot attribute a bare "N tests" to this repo.
  VAULT = /turf-vault/i

  # A stated measurement about that lane. Word-numbers included because the
  # corrected prose writes "FIVE lanes" and a digits-only pattern would read
  # straight past it.
  NUM = /\d+|one|two|three|four|five|six|seven|eight|nine|ten/i

  # The adjectives a lane count wears in this house.
  QUALIFIER = /real|CI|gate|Node|Rust/i

  # ATTRIBUTION IS PER FIGURE TYPE, and that distinction is what keeps the guard
  # honest rather than merely loud:
  #
  #   :always    — the pattern NAMES turf-vault's toolchain, so nothing else in
  #                this ecosystem's docs can produce it. `node:test` and `cargo`
  #                belong to exactly one repo here.
  #   :proximity — "lanes" and durations are ecosystem-wide words. `bin/fast-check`
  #                has three lanes of its own and `bin/ecosystem-build` runs ~30s
  #                warm; both were flagged by a first draft that attributed every
  #                figure in a paragraph to any turf-vault mention in it. So these
  #                two must find the SUBJECT near the figure itself.
  #   :vault     — a bare "N tests/cases" names no toolchain at all, so it must find
  #                the repo NAME near it, not merely a shared script name.
  #
  # THE LANE PATTERN IS SPLIT PLURAL/SINGULAR, and that is a false-positive fix, not
  # tidiness. A single `lanes?` made "one lane" a lane count, and `bin/fast-check`
  # says "the cert still died on `bin/rubocop` one lane later" — a TIME IDIOM, inside
  # a turf-vault paragraph, correct as written. Widening the population surfaced it
  # immediately. A real lane count in this house is plural ("FIVE lanes", "four CI
  # lanes" — every fixture below) or carries a qualifier; a bare singular is prose.
  FIGURES = [
    [/\b(?:#{NUM})\s+(?:(?:#{QUALIFIER})\s+)*lanes\b/i, "a lane count",           :proximity],
    [/\b(?:#{NUM})\s+(?:#{QUALIFIER})\s+lane\b/i,       "a lane count",           :proximity],
    [/\b\d+\s+[`*]*node:test[`*]*\s+cases?\b/i,         "a node:test case count", :always],
    [/\b\d+\s+Rust\s+tests?\b/i,                        "a Rust test count",      :always],
    # THE DURATION WINDOW CROSSES A LINE BREAK, never a period. At `[^.\n]{0,20}` the
    # classic rot form — "Measured warm on this laptop 2026-09-14: ~1s total", the
    # exact string that was live in release_repos.yml — matched NEITHER pattern even
    # with the subject present, because the gap is 28 characters and prose wraps.
    [/~?\d+(?:\.\d+)?\s*s(?:ec(?:onds?)?)?\b[^.]{0,40}\b(?:warm|cold)\b/i, "a lane duration", :proximity],
    [/\b(?:warm|cold)\b[^.]{0,40}~?\d+(?:\.\d+)?\s*s(?:ec(?:onds?)?)?\b/i, "a lane duration", :proximity]
  ].freeze

  # A stated case/test total for that Node suite. The `node:test` spelling carries its
  # own attribution; the bare spelling must find the repo name.
  COUNTS = [
    [/\b\d+\s+[`*]*node:test[`*]*\s+(?:cases?|tests?)\b/i, :always],
    [/\b\d+\s+(?:cases?|tests?)\b/i,                       :vault]
  ].freeze

  # How close the SUBJECT must sit to a :proximity figure. Wide enough to cross a
  # clause and a line break (every real site names the repo in the same sentence),
  # narrow enough that a turf-vault mention ten lines up cannot adopt an unrelated
  # number. Tuned against the live tree: at this width the repo is clean and every
  # fixture below still bites.
  NEAR = 200

  # What re-derives a figure. Each PRINTS the number it backs, or pins the tree it
  # was read from. `bin/release-check` bare is absent on purpose — see the header.
  PROVENANCE = [
    [/bin\/release-check\s+--list/,          "`bin/release-check --list`"],
    [/npm\s+run\s+test:scripts/,             "`npm run test:scripts`"],
    [/cargo\s+test\s+--workspace/,           "`cargo test --workspace --locked`"],
    [/\b(?=[0-9a-f]{7,40}\b)(?=[a-f0-9]*\d)[0-9a-f]{7,40}\b/, "a commit SHA"]
  ].freeze

  # Markers that the skip-then-return caveat is being CARRIED.
  #
  # `node_modules` WAS ON THIS LIST AND IS NOT ANY MORE, by the same rule the header
  # states for provenance: naming `node_modules` identifies the condition's SUBJECT,
  # not the condition. modules/zap-protocol.md proved the difference — it said the
  # Node lanes "passed 171 tests with `node_modules` absent … because they use node
  # builtins only", which names the marker while asserting its opposite. Measured by
  # carl on origin/accepted with no node_modules: `tests 171 / pass 168 / skipped 3`,
  # so BOTH halves of that sentence were false and the guard walked past it because
  # the marker was present. What counts is saying what SKIPS or what EXECUTES.
  CAVEAT = /
    \bskip(?:s|ped|ping)?\b
    | \bpass\s+168\b
    | executed\s+assertions
  /xi

  # Live prose an agent may act on — markdown anywhere, plus the comment bodies of
  # config/app/lib/bin. Frozen records, vendored trees, nested desks and this suite's
  # own fixtures are dropped by the shared population; see test/support/stated_prose.rb
  # for why each, and test/docs/guard_population_test.rb for the tripwire that keeps
  # both guards reading the same one.
  def guarded_docs
    StatedProse.sources(Rails.root)
  end

  # Blank-line separated blocks. A paragraph is the unit that makes a claim, so it
  # is the unit that owes the claim's provenance — and unlike a character window it
  # cannot borrow a command from an unrelated neighbour.
  def paragraphs(text)
    line = 1
    text.split(/\n[ \t]*\n/).map do |block|
      at = line
      line += block.count("\n") + 2
      [at, block]
    end
  end

  # Every occurrence of `pattern` in `block` that this guard reads as a claim about
  # turf-vault's lane — :always by the pattern itself, :proximity/:vault by a subject
  # within NEAR characters of the match — paired with the match's own line offset
  # inside the block.
  #
  # THE OFFSET IS WHY THIS RETURNS A PAIR. Reporting the PARAGRAPH's first line sent
  # a reader to the top of a 2,800-character comment block in release_repos.yml, more
  # than twenty lines above the figure. An offender a reader cannot find is an
  # offender that gets muted.
  def attributed(block, pattern, attribution)
    subject = attribution == :vault ? VAULT : SUBJECT

    block.to_enum(:scan, pattern).filter_map do
      match = Regexp.last_match
      offset = block[0...match.begin(0)].count("\n")
      next [match[0], offset] if attribution == :always

      from = [match.begin(0) - NEAR, 0].max
      window = block[from...(match.end(0) + NEAR)].to_s
      window.match?(subject) ? [match[0], offset] : nil
    end
  end

  def unpinned_figures(text)
    paragraphs(text).flat_map do |at, block|
      next [] unless block.match?(SUBJECT)

      stated = FIGURES.flat_map do |pattern, what, attribution|
        attributed(block, pattern, attribution).map { |hit, offset| [what, hit, offset] }
      end
      next [] if stated.empty?
      next [] if PROVENANCE.any? { |pattern, _| block.match?(pattern) }

      stated.map { |what, hit, offset| [at + offset, what, hit.gsub(/\s+/, " ").strip] }
    end
  end

  # NO PARAGRAPH-LEVEL SUBJECT GATE HERE, deliberately, and the omission is measured.
  # The `node:test` spelling is :always for a reason — it is turf-vault's toolchain
  # and nothing else in this ecosystem produces it — so a paragraph gate on SUBJECT
  # would override that and let a bare count through whenever the prose happened not
  # to name the repo or the script. Adding one silently un-bit this guard's own
  # "a corrected count that still overstates what executes" fixture. Attribution is
  # per pattern; that is the whole point of the table.
  def uncaveated_counts(text)
    paragraphs(text).flat_map do |at, block|
      stated = COUNTS.flat_map { |pattern, attribution| attributed(block, pattern, attribution) }
      next [] if stated.empty?
      next [] if block.match?(CAVEAT)

      stated.map { |hit, offset| [at + offset, hit.gsub(/\s+/, " ").strip] }
    end
  end

  # ── The live tree ─────────────────────────────────────────────────────────
  # THE CARVE-OUT MUST NOT SWALLOW A LIVE FILE. A frozen-banner exemption turns BOTH
  # tests off for the whole file, so an over-broad banner is a guard that reports green
  # because it never looked. Measured at review 2026-09-22: matching a bare `ARCHIVED`
  # exempted system/devops-cycle-design.md, system/mission.md, system/news-pipeline.md
  # and topics/data-model.md — every one of them on the task STAGE word in a lifecycle
  # list, and the first of them the canonical DevOps spec.
  def test_the_frozen_carve_out_exempts_only_genuinely_frozen_files
    exempt = StatedProse.candidates(Rails.root) - StatedProse.sources(Rails.root)

    assert_operator exempt.size, :>, 0,
                    "nothing is exempt, so this test proves nothing about the carve-out — " \
                    "re-derive it rather than deleting it"

    exempt.each do |path|
      head = File.readlines(path).first(10).join
      assert_match(StatedProse::FROZEN_BANNER, head,
                   "#{path} is exempt from BOTH turf-vault lane tests, but its first ten lines " \
                   "carry no explicit frozen banner. A live file silently exempted is worse than " \
                   "no guard, because it reports green. If this is the task STAGE word `archived` " \
                   "in a lifecycle list, narrow FROZEN_BANNER — do not add the file to a list.")
    end

    refute_includes exempt.map { |p| StatedProse.rel(Rails.root, p) },
                    "docs/agents/system/devops-cycle-design.md",
                    "the canonical DevOps spec is exempt from this guard. That is the exact " \
                    "regression this test exists for."
  end

  def test_every_turf_vault_lane_figure_is_pinned_to_its_re_derivation
    offenders = guarded_docs.flat_map do |path|
      unpinned_figures(StatedProse.prose(path)).map do |at, what, excerpt|
        "#{StatedProse.rel(Rails.root, path)}:#{at} — states #{what} (#{excerpt}) with nothing to re-derive it"
      end
    end

    assert_empty offenders, <<~MSG
      A source states a measured figure about turf-vault's `bin/release-check` without
      anything in the same paragraph that re-derives it. Put the command that PRINTS
      the number beside it — `bin/release-check --list` for the lane table,
      `npm run test:scripts` or `cargo test --workspace --locked` for the suite
      totals — or the SHA it was measured at. Naming `bin/release-check` alone is
      not provenance: that identifies the subject, not the value. Neither is a date;
      "measured 2026-09-14 at ~1s warm" is exactly the form that rotted.

      This reads COMMENTS as well as markdown, because the registry that DECLARES the
      lane and the script that RUNS it are the two most authoritative places to state
      one, and both sit outside `docs/`.

      Measured 2026-09-22 at origin/accepted 09cdfb3: 5 lanes, 76s cold / 1-2s warm,
      171 node:test cases, 60 Rust tests.

      #{offenders.join("\n")}
    MSG
  end

  def test_a_stated_case_count_carries_the_self_skip_caveat
    offenders = guarded_docs.flat_map do |path|
      uncaveated_counts(StatedProse.prose(path)).map do |at, excerpt|
        "#{StatedProse.rel(Rails.root, path)}:#{at} — states #{excerpt} as if all of them run"
      end
    end

    assert_empty offenders, <<~MSG
      A source states turf-vault's suite count without the condition that makes it
      true. Three of the cases self-skip when `node_modules` is absent (CI's guards
      lane, and any fresh clone): the summary reads `pass 168 / skipped 3`, and those
      three print as `ok <n> … # SKIP` — pass-SHAPED, so a scan for `not ok` sees
      nothing wrong. Say what executes, or say the caveat.

      Naming `node_modules` is NOT the caveat — modules/zap-protocol.md named it while
      claiming the lanes "use node builtins only", which is false for exactly those
      three cases. Say what SKIPS or what EXECUTES.

      #{offenders.join("\n")}
    MSG
  end

  # ── The checker itself bites ──────────────────────────────────────────────
  #
  # The first three fixtures are VERBATIM from the three sites as they stood before
  # this task, so the guard is pinned against the real defect rather than against a
  # phrasing invented to match the regex. The last three are the NON-DOCS sites the
  # widened population found, also verbatim — they are the reason the fix cannot be
  # "delete the offending comment": the guard keeps biting on the text either way.
  REGRESSIONS = {
    "claude.md / index.md, verbatim" =>
      "thing — `bin/release-check`, a script that repo owns: **studio-engine** and\n" \
      "**solana-studio** (under `gems:`, registered 2026-08-31) and **turf-vault** (under\n" \
      "`apps:`, declared 2026-09-14 and repointed at its own script the same day; it runs\n" \
      "that repo's four CI lanes, ~1s warm, 61 `node:test` cases among them).",
    "g1-cert.md, verbatim — a DATE is not provenance" =>
      "runs) and turf-vault (its four CI lanes, measured 2026-09-14 at ~1s warm). So a\n" \
      "studio-engine OR a turf-vault builder CAN use the fast route.",
    "g1-cert.md's historical aside, verbatim" =>
      "reach this branch however completely it declared its lane — which is why\n" \
      "turf-vault had four real CI lanes and no local cert for months.",
    "bin/fast-check's comment, verbatim — a SCRIPT outside docs/" =>
      "to ask `gem_repo?`, which meant an `apps` row could never reach it however\n" \
      "completely it declared its lane — so turf-vault, an Anchor repo with four real CI\n" \
      "lanes, had no local cert at all and every reader was routed to a task to decide",
    "the release-repo registry's key doc, verbatim — a REGISTRY outside docs/" =>
      "turf-vault declared its four CI lanes here as a chain for one day\n" \
      "(2026-09-14) before growing its own `bin/release-check`, and a\n" \
      "chain in this file is a COPY of another repo's CI that drifts",
    "the release-repo registry's turf-vault row, verbatim" =>
      "THE VALUE IS A SCRIPT THE REPO OWNS, which is the whole point of the key and was\n" \
      "not true for its first day. Until 2026-09-14 this row spelled turf-vault's four\n" \
      "lanes out as a `&&` chain, because the repo shipped no bin/ directory to point at.",
    "the NEXT rot: a correct count today, bare tomorrow" =>
      "turf-vault's `bin/release-check` runs five CI lanes and 171 `node:test` cases.",
    "naming the script is not deriving the figure" =>
      "Run `bin/release-check` in the turf-vault desk; its five lanes finish in ~1s warm.",
    "a Rust count with nothing behind it" =>
      "The turf-vault program carries 60 Rust tests alongside the Node guards.",
    "a duration written the other way round" =>
      "turf-vault's release-check is cold at 76s and warm at 2s.",
    "the wrapped-duration form the narrow window used to miss" =>
      "turf-vault's `bin/release-check`: measured warm on this laptop\n" \
      "2026-09-14: ~1s total."
  }.freeze

  def test_the_checker_catches_every_original_phrasing
    REGRESSIONS.each do |label, prose|
      assert_not_empty unpinned_figures(prose),
                       "#{label}: this is the defect the guard exists for and it read as clean"
    end
  end

  UNCAVEATED = {
    "the bare count this task removed" =>
      "turf-vault runs that repo's four CI lanes, ~1s warm, 61 `node:test` cases among them.",
    "a corrected count that still overstates what executes" =>
      "`npm run test:scripts` carries 171 `node:test` cases, measured at `09cdfb3`.",
    "zap-protocol.md, verbatim — names node_modules, asserts its opposite" =>
      "`turf-vault`'s two Node lanes — `npm run check:doc-op-refs` and `npm run\n" \
      "test:scripts`, the ones its `bin/release-check` runs first — passed **171 tests\n" \
      "with `node_modules` absent** on a fresh detached worktree (measured 2026-09-22),\n" \
      "because they use node builtins only; its Rust lanes rebuild `target/`\n" \
      "themselves, slowly and greenly."
  }.freeze

  def test_the_caveat_checker_catches_a_bare_count
    UNCAVEATED.each do |label, prose|
      assert_not_empty uncaveated_counts(prose),
                       "#{label}: a count stated as if all of it executes read as clean"
    end
  end

  # The other half of a guard that means anything: correct prose must pass. A guard
  # that cries wolf on its own fix gets muted, and then it protects nothing. These
  # are the live sentences this task wrote.
  ACCEPTED = {
    "the corrected claude.md / index.md paragraph" =>
      "**Budget turf-vault's lane at FIVE lanes and 76s cold — not four and \"~1s\".**\n" \
      "Measured 2026-09-22 against `origin/accepted` at `09cdfb3`: two Node lanes, then\n" \
      "`cargo check`, `cargo clippy` and `cargo test`. The suite is **171 `node:test`\n" \
      "cases** and **60 Rust tests**. But 171 is not 171 executed assertions: with no\n" \
      "`node_modules`, three self-skip and the summary reads `pass 168 / skipped 3`.\n" \
      "**Re-derive these figures; never re-copy them:** `bin/release-check --list`\n" \
      "prints the lane table, and `npm run test:scripts` and\n" \
      "`cargo test --workspace --locked` print their own totals.",
    "the corrected g1-cert line" =>
      "runs) and turf-vault (**five** lanes — two Node, three Rust — measured\n" \
      "2026-09-22 against `origin/accepted` at `09cdfb3`: **76s cold**, 1-2s on a\n" \
      "re-run; re-derive the table with `bin/release-check --list` rather than\n" \
      "trusting this line).",
    "prose about turf-vault that states no figure at all" =>
      "**Never record a \"no tests\" skip for turf-vault.** It has a suite and now has\n" \
      "a lane to run it.",
    "the stale-primary warning, which counts nothing" =>
      "On 2026-09-22 that primary sat at `66ffff1` with no `bin/` directory at all,\n" \
      "while `origin/accepted` carried the script.",
    # THE FALSE RED THE WIDER POPULATION FOUND. `bin/fast-check` says this inside a
    # turf-vault paragraph, and "one lane later" is a TIME IDIOM, not a lane count.
    # A guard that reds on correct text trains people to route around it.
    "bin/fast-check's time idiom, verbatim — 'one lane later'" =>
      "The two facts are independent even so, and turf-vault is why:\n" \
      "bin/full-suite-check runs a lint lane for every repo and reads the declaration,\n" \
      "so without `lint_lane: none` its declared gate went green and the cert still\n" \
      "died on `bin/rubocop` one lane later.",
    "a single qualified lane, which IS a count and must still bite elsewhere" =>
      "turf-vault's guards job is one CI lane, re-derive with `bin/release-check --list`."
  }.freeze

  def test_the_checker_passes_correct_prose
    ACCEPTED.each do |label, prose|
      assert_empty unpinned_figures(prose),
                   "#{label}: correct prose was flagged — a guard that cries wolf gets muted"
      assert_empty uncaveated_counts(prose),
                   "#{label}: correct prose was flagged by the caveat check"
    end
  end
end
