# frozen_string_literal: true

require "test_helper"

# GUARD (turf-vault-lane-figure, 2026-09-22): a hub doc that states a MEASURED
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
class TurfVaultLaneFigureDocsTest < ActiveSupport::TestCase
  # The repo the figure is about. Without this every "5 lanes" in the tree trips.
  SUBJECT = /turf-vault|release-check/i

  # A stated measurement about that lane. Word-numbers included because the
  # corrected prose writes "FIVE lanes" and a digits-only pattern would read
  # straight past it.
  NUM = /\d+|one|two|three|four|five|six|seven|eight|nine|ten/i

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
  FIGURES = [
    [/\b(?:#{NUM})\s+(?:real\s+|CI\s+|gate\s+|Node\s+|Rust\s+)*lanes?\b/i, "a lane count",           :proximity],
    [/\b\d+\s+[`*]*node:test[`*]*\s+cases?\b/i,                            "a node:test case count", :always],
    [/\b\d+\s+Rust\s+tests?\b/i,                                           "a Rust test count",      :always],
    [/~?\d+(?:\.\d+)?\s*s(?:ec(?:onds?)?)?\b[^.\n]{0,20}\b(?:warm|cold)\b/i, "a lane duration",       :proximity],
    [/\b(?:warm|cold)\b[^.\n]{0,20}~?\d+(?:\.\d+)?\s*s(?:ec(?:onds?)?)?\b/i, "a lane duration",       :proximity]
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

  # Markers that the skip-then-return caveat is being carried.
  CAVEAT = /
    node_modules
    | \bskip(?:s|ped|ping)?\b
    | \bpass\s+168\b
    | executed\s+assertions
  /xi

  # A doc that declares itself a snapshot is a record of what was true on its date.
  # Correcting its figures would falsify the record, so it is out of scope — the
  # same carve-out the CURRENT_DEPLOYMENT guard makes for banner-marked history.
  # NOT a bare ARCHIVED, and the omission is the whole correctness of this carve-out.
  # `archived` is a task STAGE in this house, printed in the lifecycle list near the top
  # of a spec — so matching it exempted FOUR LIVE DOCS from both tests, measured at
  # review 2026-09-22: system/devops-cycle-design.md (on "shipped → archived"),
  # system/mission.md, system/news-pipeline.md and topics/data-model.md. The canonical
  # DevOps spec silently carrying no guard is the guard failing at birth. Both files
  # this carve-out exists for say ARCHIVE-ONLY in as many words
  # (system/ecosystem-audit-2026-05-17.md, system/squads-upgrade-authority-migration.md),
  # so the explicit banner is enough and the stage word is pure collateral.
  FROZEN_BANNER = /ARCHIVE-ONLY|HISTORICAL RECORD|POINT-IN-TIME|AUDIT SNAPSHOT/i

  # Live prose an agent may act on. Frozen records state what was true on their
  # date and must not be rewritten; test/ holds this file's own fixtures.
  def guarded_docs
    Dir.glob(Rails.root.join("docs", "**", "*.md")).reject do |path|
      path.include?("/archive") || path.include?("/audits/") ||
        path.include?("/node_modules/") ||
        File.read(path).lines.first(10).any? { |l| l.match?(FROZEN_BANNER) }
    end
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
  # turf-vault's lane — :always by the pattern itself, :proximity by a SUBJECT
  # within NEAR characters of the match.
  def attributed(block, pattern, attribution)
    block.to_enum(:scan, pattern).filter_map do
      match = Regexp.last_match
      next match[0] if attribution == :always

      from = [match.begin(0) - NEAR, 0].max
      window = block[from...(match.end(0) + NEAR)].to_s
      window.match?(SUBJECT) ? match[0] : nil
    end
  end

  def unpinned_figures(text)
    paragraphs(text).flat_map do |at, block|
      next [] unless block.match?(SUBJECT)

      stated = FIGURES.flat_map do |pattern, what, attribution|
        attributed(block, pattern, attribution).map { |hit| [what, hit] }
      end
      next [] if stated.empty?
      next [] if PROVENANCE.any? { |pattern, _| block.match?(pattern) }

      stated.map { |what, hit| [at, what, hit.gsub(/\s+/, " ").strip] }
    end
  end

  # No SUBJECT test here, deliberately: a `node:test` case count in this ecosystem's
  # docs is turf-vault's by construction — it is the only repo with that suite — so
  # the count carries its own attribution, exactly as the :always figures do above.
  def uncaveated_counts(text)
    paragraphs(text).filter_map do |at, block|
      count = block[/\b\d+\s+[`*]*node:test[`*]*\s+cases?\b/i]
      next unless count
      next if block.match?(CAVEAT)

      [at, count.gsub(/\s+/, " ").strip]
    end
  end

  # ── The live tree ─────────────────────────────────────────────────────────
  # THE CARVE-OUT MUST NOT SWALLOW A LIVE DOC. A frozen-banner exemption turns BOTH
  # tests off for the whole file, so an over-broad banner is a guard that reports green
  # because it never looked. Measured at review 2026-09-22: matching a bare `ARCHIVED`
  # exempted system/devops-cycle-design.md, system/mission.md, system/news-pipeline.md
  # and topics/data-model.md — every one of them on the task STAGE word in a lifecycle
  # list, and the first of them the canonical DevOps spec.
  def test_the_frozen_carve_out_exempts_only_genuinely_frozen_files
    all = Dir.glob(Rails.root.join("docs", "**", "*.md")).reject do |path|
      path.include?("/archive") || path.include?("/audits/") || path.include?("/node_modules/")
    end
    exempt = all - guarded_docs

    assert_operator exempt.size, :>, 0,
                    "nothing is exempt, so this test proves nothing about the carve-out — " \
                    "re-derive it rather than deleting it"

    exempt.each do |path|
      head = File.readlines(path).first(10).join
      assert_match(/ARCHIVE-ONLY|HISTORICAL RECORD|POINT-IN-TIME|AUDIT SNAPSHOT/i, head,
                   "#{path} is exempt from BOTH turf-vault lane tests, but its first ten lines " \
                   "carry no explicit frozen banner. A live doc silently exempted is worse than " \
                   "no guard, because it reports green. If this is the task STAGE word `archived` " \
                   "in a lifecycle list, narrow FROZEN_BANNER — do not add the file to a list.")
    end

    refute_includes exempt.map { |p| p.sub("#{Rails.root}/", "") }, "docs/agents/system/devops-cycle-design.md",
                    "the canonical DevOps spec is exempt from this guard. That is the exact " \
                    "regression this test exists for."
  end

  def test_every_turf_vault_lane_figure_is_pinned_to_its_re_derivation
    offenders = guarded_docs.flat_map do |path|
      unpinned_figures(File.read(path)).map do |at, what, excerpt|
        "#{path.sub("#{Rails.root}/", '')}:~#{at} — states #{what} (#{excerpt}) with nothing to re-derive it"
      end
    end

    assert_empty offenders, <<~MSG
      A doc states a measured figure about turf-vault's `bin/release-check` without
      anything in the same paragraph that re-derives it. Put the command that PRINTS
      the number beside it — `bin/release-check --list` for the lane table,
      `npm run test:scripts` or `cargo test --workspace --locked` for the suite
      totals — or the SHA it was measured at. Naming `bin/release-check` alone is
      not provenance: that identifies the subject, not the value. Neither is a date;
      "measured 2026-09-14 at ~1s warm" is exactly the form that rotted.

      Measured 2026-09-22 at origin/accepted 09cdfb3: 5 lanes, 76s cold / 1-2s warm,
      171 node:test cases, 60 Rust tests.

      #{offenders.join("\n")}
    MSG
  end

  def test_a_stated_case_count_carries_the_self_skip_caveat
    offenders = guarded_docs.flat_map do |path|
      uncaveated_counts(File.read(path)).map do |at, excerpt|
        "#{path.sub("#{Rails.root}/", '')}:~#{at} — states #{excerpt} as if all of them run"
      end
    end

    assert_empty offenders, <<~MSG
      A doc states turf-vault's `node:test` case count without the condition that
      makes it true. Three of the cases self-skip when `node_modules` is absent (CI's
      guards lane, and any fresh clone): the summary reads `pass 168 / skipped 3`,
      and those three print as `ok <n> … # SKIP` — pass-SHAPED, so a scan for
      `not ok` sees nothing wrong. Say what executes, or say the caveat.

      #{offenders.join("\n")}
    MSG
  end

  # ── The checker itself bites ──────────────────────────────────────────────
  #
  # The first three fixtures are VERBATIM from the three sites as they stood before
  # this task, so the guard is pinned against the real defect rather than against a
  # phrasing invented to match the regex.
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
    "the NEXT rot: a correct count today, bare tomorrow" =>
      "turf-vault's `bin/release-check` runs five CI lanes and 171 `node:test` cases.",
    "naming the script is not deriving the figure" =>
      "Run `bin/release-check` in the turf-vault desk; its five lanes finish in ~1s warm.",
    "a Rust count with nothing behind it" =>
      "The turf-vault program carries 60 Rust tests alongside the Node guards.",
    "a duration written the other way round" =>
      "turf-vault's release-check is cold at 76s and warm at 2s."
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
      "`npm run test:scripts` carries 171 `node:test` cases, measured at `09cdfb3`."
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
      "while `origin/accepted` carried the script."
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
