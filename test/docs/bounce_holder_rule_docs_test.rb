# frozen_string_literal: true

require "test_helper"

# ONLY THE REVIEW CLAIM'S HOLDER MAY SPEND THE BOUNCE — pinned repo-wide, across
# prose AND the code that GENERATES prose.
#
# THE CLASS THIS CLOSES. Sixteen sites granted the bounce to "any reviewer", and
# they were corrected in THREE passes by three agents, each of which believed it
# had finished: PR #1270 swept some and left 8+ standing, PR #1272 swept 15 more
# by hand, and light-prompt-grants-block closed the sixteenth in `bin/pr-review`.
# Nothing pinned the rule, so pass N+1 was always one edit away. This guard is the
# thing that makes a seventeenth site fail instead of ship.
#
# WHY A REPO-WIDE SWEEP, AND NOT A DOCS ONE. The worst of the sixteen was not in
# `docs/` at all — it was a Ruby STRING LITERAL in `bin/pr-review` building the
# light reviewer's spawn prompt. A guard that reads only `docs/` cannot see the
# code that writes prose, so this sweeps `docs/ bin/ lib/ app/ config/ .github/`.
#
# WHY NEVER BY EXTENSION. `grep --include='*.rb'` silently skips `bin/task`,
# `bin/dor-check`, `bin/pr-review` and `bin/ship` — they are Ruby with NO
# extension, and 71 files in this corpus are. Two independent agents lost the
# same surviving grant to exactly that filter, on exactly that file. The blind
# spot is structural, so the defence is structural: this enumerates by PATH and
# CONTENT, and `test_the_sweep_can_see_extensionless_bin_scripts` fails if the
# blind spot ever reopens.
#
# THE RULE IS A CONDITION, NOT A FLAT PROHIBITION — and getting this wrong is how
# a guard becomes a false claim in its own right. The gate is
# `GATED_KINDS = %w[rework]` with `ALLOWED = [NOT_GATED, NO_REVIEW, OWNER]`
# (lib/review_verdict_gate.rb), so THREE of its six verdicts pass: `--kind
# dependency` and `--kind environment` are NOT_GATED, a task with no live review
# claim is NO_REVIEW, and the holder is OWNER. "A light may not block" is
# therefore WRONG in half the cases, and this guard never asserts it. What it
# pins is the conditional: while a review claim is LIVE, a `--kind rework` block
# by a soul other than the holder is refused (exit 11).
#
# Deliberately NOT pinned: pr-review-light.md's absolute "Never run `bin/task
# block` on the task you are reviewing." That is STRICTER than the gate, and Carl
# judged it defensible house policy for a light — a second read has no business
# filing dependency or environment blocks either. It is policy, not a misstatement
# of the gate, so this guard leaves it alone rather than forcing it looser.
class BounceHolderRuleDocsTest < ActiveSupport::TestCase
  ROOTS = %w[docs bin lib app config .github].freeze
  SKIP_DIRS = %r{/(node_modules|tmp|vendor|\.git|builds)/}

  class << self
    def corpus
      @corpus ||= ROOTS.each_with_object({}) do |root, acc|
        base = Rails.root.join(root)
        next unless base.exist?

        Dir.glob(base.join("**", "*").to_s).sort.each do |abs|
          next unless File.file?(abs)

          rel = Pathname.new(abs).relative_path_from(Rails.root).to_s
          next if "/#{rel}".match?(SKIP_DIRS)

          text = read_text(abs)
          acc[rel] = text if text
        end
      end
    end

    # Binary-safe by construction. A single invalid byte anywhere in the corpus
    # must not raise and abort the walk — a reader that dies partway through is
    # precisely how a guard reports green while having examined nothing. (It
    # happened while deriving this guard: the first sweep died on a binary file
    # and printed a confident, partial answer.)
    def read_text(abs)
      raw = File.binread(abs)
      return nil if raw[0, 8192].to_s.include?("\x00")

      raw.force_encoding(Encoding::UTF_8).scrub("?")
    rescue StandardError
      nil
    end
  end

  # Normalise for phrase matching: strip LINE-LEADING comment markers so a phrase
  # split across two `#` comment lines still reads as one run (without this,
  # "a light # reviewer's block counts" evades the pattern — measured), drop
  # markdown emphasis, and collapse whitespace so a wrapped sentence or a
  # backslash-continued command joins up.
  def flat(text)
    text.lines.map { |line| line.sub(/\A\s*#+\s?/, " ") }.join(" ")
        .gsub(/[*`>]/, "").gsub(/\s+/, " ")
  end

  BLOCK_CMD = "bin/task block"
  REWORK = /--kind (rework|<[^>]*rework)/

  # ONE run = ONE invocation. A run ends at the sentence end, at the NEXT
  # invocation, or after 220 characters — whichever comes first.
  #
  # Stopping at the next invocation is load-bearing, and it is not hypothetical:
  # the first cut of this guard scanned a fixed-width window, so two commands in
  # one sentence became a SINGLE run and a later agented command masked an earlier
  # bare one. The mutation that reintroduced an un-agented gate-zero bounce — the
  # exact defect this guard exists to catch — SURVIVED that version.
  def rework_runs(text)
    body = flat(text)
    runs = []
    idx = body.index(BLOCK_CMD)
    while idx
      nxt = body.index(BLOCK_CMD, idx + BLOCK_CMD.length)
      stop = [idx + 220, body.length, nxt].compact.min
      seg = body[idx...stop]
      dot = seg.index(".")
      seg = seg[0...dot] if dot
      runs << seg if seg.match?(REWORK)
      idx = nxt
    end
    runs
  end

  # ---------------------------------------------------------------------------
  # 0. THE SWEEP MUST BE PROVEN TO HAVE READ SOMETHING.
  # ---------------------------------------------------------------------------

  test "[unit] the sweep enumerates by path and content, and can see extensionless bin/ scripts" do
    corpus = self.class.corpus
    assert_operator corpus.size, :>, 400,
      "the sweep read #{corpus.size} files — it should see the whole of #{ROOTS.join(' ')}; " \
      "a collapsed corpus means the reader broke and every assertion below is vacuous"

    extensionless = corpus.keys.reject { |rel| File.basename(rel).include?(".") }
    assert_operator extensionless.size, :>, 40,
      "only #{extensionless.size} extensionless files in the corpus — the `*.rb` blind spot has reopened"

    # The exact four that `--include='*.rb'` drops on the floor.
    %w[bin/task bin/pr-review bin/dor-check bin/ship].each do |rel|
      assert_includes corpus.keys, rel, "#{rel} must be swept — it is Ruby with no extension"
      assert_operator corpus[rel].to_s.length, :>, 2_000,
        "#{rel} read back as #{corpus[rel].to_s.length} bytes — the reader is truncating"
    end

    ROOTS.each do |root|
      assert corpus.keys.any? { |rel| rel.start_with?("#{root}/") },
        "no file swept under #{root}/ — a whole root dropped out of the corpus"
    end
  end

  # The strongest anti-vacuous proof available: exercise the ACTUAL machinery the
  # rules below depend on (read → flatten → extract) and require it to find real
  # runs in BOTH file shapes. If the reader, the flattener or the extractor breaks,
  # this fails loudly instead of letting the rules pass on an empty scan.
  test "[unit] the run extractor finds real block invocations in both a bare script and a markdown doc" do
    corpus = self.class.corpus

    script_runs = rework_runs(corpus.fetch("bin/task"))
    assert_operator script_runs.size, :>=, 1,
      "extracted no `--kind rework` runs from bin/task — the extractor is blind to extensionless scripts, " \
      "which is the exact failure this guard exists to prevent"

    doc_runs = rework_runs(corpus.fetch("docs/agents/modules/pr-review-sop.md"))
    assert_operator doc_runs.size, :>=, 2,
      "extracted #{doc_runs.size} `--kind rework` runs from pr-review-sop.md — the extractor is not reading markdown"

    assert doc_runs.any? { |run| run.include?("--agent") },
      "pr-review-sop.md must carry at least one agented block command for the extractor to see"
  end

  # ---------------------------------------------------------------------------
  # 1. THE GRANT MUST NOT COME BACK (negative).
  # ---------------------------------------------------------------------------

  GRANT_PATTERNS = {
    "any-reviewer-can-block" => /any reviewer can (still )?block/i,
    "any-reviewer-can-stop" => /any reviewer can stop/i,
    "any-reviewer-may-block" => /any reviewer may block/i,
    "reviewer-marks-blocked" => /any\s?reviewer marks the task blocked/i,
    "light-block-counts" => /light reviewer'?s? block counts/i
  }.freeze

  # The ONLY sanctioned occurrences, each pinned to one file with its reason.
  # `lib/review_verdict_gate.rb`'s header QUOTES the three grants it was written
  # to kill, as the record of what the prose used to say — deleting the quotes
  # would delete the evidence. Every entry is liveness-checked below, so a stale
  # exemption FAILS rather than quietly widening into a blanket pass for its file.
  GRANT_EXEMPTIONS = [
    { file: "lib/review_verdict_gate.rb", pattern: "any-reviewer-can-block",
      why: "header quotes pr-review-light.md's retired Scope line as the defect record" },
    { file: "lib/review_verdict_gate.rb", pattern: "any-reviewer-can-stop",
      why: "header quotes the retired request-changes bullet as the defect record" },
    { file: "lib/review_verdict_gate.rb", pattern: "light-block-counts",
      why: "header quotes the retired request-changes bullet as the defect record" }
  ].freeze

  test "[integration] no file grants the bounce to any reviewer" do
    offenders = []
    self.class.corpus.each do |rel, text|
      body = flat(text)
      GRANT_PATTERNS.each do |name, pattern|
        next unless body.match?(pattern)
        next if GRANT_EXEMPTIONS.any? { |e| e[:file] == rel && e[:pattern] == name }

        offenders << "#{rel} [#{name}] …#{body[[(body =~ pattern) - 40, 0].max, 150]}…"
      end
    end

    assert_empty offenders, <<~MSG
      The bounce is granted to "any reviewer" in #{offenders.size} place(s):

      #{offenders.join("\n      ")}

      Only the soul the review claim records as its HOLDER may SPEND a task's bounce
      (lib/review_verdict_gate.rb — a `--kind rework` block by anyone else exits 11
      and writes nothing). Any reviewer may RAISE the finding; a light records it with
      `bin/task note <task> --comment "…"` and the primary decides.

      If this text is a deliberate historical QUOTE of the retired wording, add it to
      GRANT_EXEMPTIONS with the reason — do not widen the pattern.
    MSG
  end

  test "[unit] every grant exemption is still live — a stale one fails rather than widening" do
    GRANT_EXEMPTIONS.each do |exemption|
      text = self.class.corpus[exemption[:file]]
      assert text, "GRANT_EXEMPTIONS names #{exemption[:file]}, which the sweep did not read"

      pattern = GRANT_PATTERNS.fetch(exemption[:pattern])
      assert_match pattern, flat(text),
        "stale exemption: #{exemption[:file]} no longer matches #{exemption[:pattern]} " \
        "(#{exemption[:why]}). Delete the entry — an exemption that matches nothing is a " \
        "standing hole in the guard."
    end
  end

  # ---------------------------------------------------------------------------
  # 2. NO RUNNABLE BOUNCE COMMAND WITHOUT ITS ACTOR (negative).
  # ---------------------------------------------------------------------------
  #
  # A block command printed WITHOUT `--agent` is as dangerous as a prose grant,
  # because someone pastes it. `resolved_block_actor` (bin/task) falls through an
  # unset `session_marker_persona` to `default_block_actor`, which returns the
  # LITERAL "avi" for `--kind rework` on a submitted task — so Carl pasting his own
  # gate-zero command grades FOREIGN against his own claim and exits 11.
  #
  # Prose that NARRATES the command ("`bin/task block --kind rework` exits 10") is
  # not a paste hazard, and no honest heuristic separates it from an instruction —
  # `pr-review-sop.md` carries both shapes with identical syntax. So the inventory
  # is EXPLICIT: a bare run must be listed here with a reason, or it fails. A
  # seventeenth site cannot arrive unnoticed, because arriving unnoticed is the
  # one thing this list makes impossible.
  NARRATION = [
    { file: "app/models/task.rb", match: /lands the task back on building and repoints/,
      why: "comment explaining the feature-marker repoint" },
    { file: "bin/pr-review", match: /with the failing checks named/,
      why: "header comment narrating the gate-zero flow" },
    { file: "bin/task", match: /lands the task back on building and ends with write_feature_marker/,
      why: "comment explaining the feature-marker repoint" },
    { file: "bin/task", match: /block \#\{slug\} --kind rework/,
      why: "SPLIT, not narration: a printed breaker-ack remedy that omits --agent. Same class, " \
           "but bin/ is out of the docs shape this guard shipped under — tracked separately." },
    { file: "docs/agents/agents/carl/sops/pr-review-light.md", match: /on its own initiative/,
      why: "cautionary account of turf-monster PR 594, the incident that motivated the gate" },
    { file: "docs/agents/agents/carl/sops/pr-review.md", match: /therefore runs the breaker itself/,
      why: "prose describing what the command does, not an instruction to run it" },
    { file: "docs/agents/modules/devops-task-board.md", match: /lands the task back on building, and three readers/,
      why: "prose describing the stage effect on board readers" },
    { file: "docs/agents/modules/gates/g2-review.md", match: /exits 10\), re-run it/,
      why: "prose naming the breaker's exit code" },
    { file: "docs/agents/modules/pr-review-sop.md", match: /lands the task on building, and every reader/,
      why: "prose describing the stage effect on board readers" },
    { file: "docs/agents/modules/pr-review-sop.md", match: /runs the same check and refuses the second bounce/,
      why: "prose describing the breaker, not an instruction to run it" },
    { file: "lib/review_verdict_gate.rb", match: /on its own initiative, then reported back to its Carl/,
      why: "header narrating the incident the gate exists to prevent" }
  ].freeze

  test "[integration] every runnable rework block command names its acting soul" do
    offenders = []
    self.class.corpus.each do |rel, text|
      rework_runs(text).each do |run|
        next if run.include?("--agent")
        next if NARRATION.any? { |n| n[:file] == rel && run.match?(n[:match]) }

        offenders << "#{rel}\n        #{run.strip[0, 150]}"
      end
    end

    assert_empty offenders, <<~MSG
      #{offenders.size} `--kind rework` block command(s) print without `--agent`:

      #{offenders.join("\n      ")}

      A bounce command with no `--agent` does NOT run as whoever pastes it.
      `resolved_block_actor` falls through an unset session persona to
      `default_block_actor`, which returns the literal "avi" for a rework block on a
      submitted task — so Carl pasting his own gate-zero command grades FOREIGN
      against his own review claim and exits 11, writing nothing.

      Fix: append `--agent <soul>` (`--agent carl` for a review-lane bounce).
      If the line NARRATES the command rather than instructing anyone to run it,
      add it to NARRATION with a reason.
    MSG
  end

  test "[unit] every narration exemption is still live — a stale one fails rather than widening" do
    corpus = self.class.corpus
    NARRATION.each do |entry|
      text = corpus[entry[:file]]
      assert text, "NARRATION names #{entry[:file]}, which the sweep did not read"

      matched = rework_runs(text).any? { |run| !run.include?("--agent") && run.match?(entry[:match]) }
      assert matched,
        "stale exemption: no bare `--kind rework` run in #{entry[:file]} matches " \
        "#{entry[:match].inspect} (#{entry[:why]}). Delete the entry — an exemption that " \
        "matches nothing is a standing hole in the guard."
    end
  end

  # ---------------------------------------------------------------------------
  # 3. THE POSITIVE RULE MUST SURVIVE, AS A CONDITION (positive).
  # ---------------------------------------------------------------------------
  #
  # Without this, a later editor satisfies every refutation above by DELETING the
  # rule — the docs would go silent on who may spend the bounce and the guard
  # would still be green. The condition is pinned in all three of its parts,
  # including the two that make the flat reading wrong.

  test "[integration] the review SOP states the holder rule as a condition, with its exceptions" do
    body = flat(self.class.corpus.fetch("docs/agents/modules/pr-review-sop.md"))

    assert_match(/any reviewer may RAISE a blocking finding/i, body,
      "the SOP must keep RAISE — any reviewer may raise the finding")
    assert_match(/only the claim's holder may SPEND/i, body,
      "the SOP must keep SPEND — only the review claim's holder spends the bounce")
    assert_match(/while a review claim is live/i, body,
      "the rule is CONDITIONAL on a live review claim — with no live claim the gate returns " \
      "NO_REVIEW and the block proceeds; dropping the qualifier overstates the gate")
    assert_match(/--kind dependency and --kind environment spend no bounce and are not gated/i, body,
      "GATED_KINDS is rework ONLY — dependency and environment are NOT_GATED. Dropping this " \
      "clause turns the rule into 'a light may never block', which is wrong in half the gate's verdicts")
    assert_match(/exit 11/i, body, "the SOP must name the refusal the rule is enforced by")
  end

  test "[integration] the G2 gate doc keeps the raise/spend split and its enforcement" do
    body = flat(self.class.corpus.fetch("docs/agents/modules/gates/g2-review.md"))

    assert_match(/any reviewer may RAISE a blocking finding/i, body,
      "G2 must keep RAISE — the light's finding is a scout report, not a refusal to file it")
    assert_match(/claim's holder is REFUSED with exit 11/i, body,
      "G2 must state the enforcement, not merely ask for the behaviour")
  end
end
