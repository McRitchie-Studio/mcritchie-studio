# frozen_string_literal: true

# bin/lib/full_suite_gate.rb — the FULL-suite + FULL-rubocop evidence contract.
#
# Shared by the two halves of the gate so the format lives in ONE place:
#   * bin/full-suite-check WRITES evidence (runs the lanes, records the tags).
#   * bin/dor-check        VALIDATES evidence (refuses a stale/partial/lint-red PR).
#
# Why this exists (devops retro, lines 54 + 58): dor-check used to TRUST a
# free-text tier tag ("[unit] ..."), so a build could satisfy a tier by running
# only the FILES it touched. The full suite or rubocop then broke post-merge.
# The fix: a task may not cross to `submitted` until the FULL `bin/rails test`
# and a FULL `bin/rubocop` have gone green against the EXACT code being shipped.
#
# The anti-stale mechanism is a content-addressed FINGERPRINT, not a SHA or a
# free-text tag. We stage the WHOLE working tree — tracked edits AND
# untracked-but-not-ignored files — into a THROWAWAY git index (GIT_INDEX_FILE)
# and hash it with `git write-tree`; a git tree hash is purely content-addressed,
# so committing the same changes produces the SAME hash. (An earlier version used
# `git stash create`, which silently DROPS untracked files — so a change that
# ADDED a file fingerprinted differently before vs after the commit and was
# wrongly read as STALE.) That gives two properties the retro needs:
#   * Freshness — edit ANY tracked OR untracked-not-ignored file after certifying
#     and the fingerprint changes, so the recorded evidence goes STALE and
#     dor-check refuses. You cannot certify a subset and then keep editing.
#   * Checkout-independence — the reviewer/heartbeat checkout at the committed
#     HEAD recomputes the SAME fingerprint the feature agent certified pre-commit,
#     so the evidence (carried on the task's devops.checks_run) validates there
#     too. tmp/ files don't travel between checkouts; a tree hash does.
#
# Evidence is recorded as two checks_run lines the runner stamps:
#   [full-suite@<fp>] bin/rails test (NNN runs, 0 failures)
#   [rubocop@<fp>]    bin/rubocop (clean)
# dor-check credits a lane only when a line is tagged for it AND the embedded
# fingerprint equals the local recomputed one. Hand-writing a green tag is not
# defended against (honor system — "Trust over guardrails"); the point is to make
# the honest path one command and to CATCH the easy mistake (touched-files subset
# + a stale tag), which a content fingerprint does deterministically.
require "tmpdir"

module FullSuiteGate
  TEST_LANE = "full-suite"
  RUBOCOP_LANE = "rubocop"
  BYPASS_TAG = "full-suite-bypass"
  LANES = [TEST_LANE, RUBOCOP_LANE].freeze

  module_function

  # Content-addressed fingerprint of the CURRENT code — tracked edits AND
  # untracked-but-not-ignored files — stable across the pre-commit→commit
  # boundary. Returns a git tree hash, or nil when git can't read the tree (no
  # repo / missing identity) — the caller treats nil as "unverifiable" and
  # refuses, since this gate's job is to refuse what it cannot confirm. `root` is
  # the repo dir (overridable in tests).
  #
  # Implementation: stage everything into a THROWAWAY index (GIT_INDEX_FILE, never
  # the real one) with `git add -A` — which honours .gitignore and DOES include
  # new files — then `git write-tree`. This is "the tree you'd get by committing
  # the whole working state", so it stays stable when an added file is later
  # committed (`git stash create` dropped untracked files and broke that).
  def fingerprint(root)
    index = File.join(Dir.tmpdir, "fsg-index-#{Process.pid}-#{rand(1 << 32)}")
    env = { "GIT_INDEX_FILE" => index }
    return nil unless run(["git", "-C", root.to_s, "add", "-A"], env: env)

    tree = capture(["git", "-C", root.to_s, "write-tree"], env: env).strip
    tree.empty? ? nil : tree
  ensure
    File.delete(index) if index && File.exist?(index)
  end

  # The checks_run line a passing lane records, embedding the fingerprint.
  def evidence_line(lane, fingerprint, detail)
    "[#{lane}@#{fingerprint}] #{detail}"
  end

  # Pattern for a recorded evidence line of EITHER lane ("[full-suite@..]" /
  # "[rubocop@..]"), at the start of a checks_run line.
  EVIDENCE_RE = /\A\s*\[\s*(?:#{LANES.map { |l| Regexp.escape(l) }.join("|")})\s*@/i

  # Merge fresh evidence lines into an existing checks_run, REPLACING any prior
  # full-suite/rubocop evidence (so re-runs don't accumulate stale lines) while
  # PRESERVING tier tags ("[unit] ..."), bypass records, and everything else. The
  # writer (bin/full-suite-check) needs this because `bin/task update --checks`
  # REPLACES the whole list — a naive write would wipe the agent's tier tags.
  def merge_evidence(existing, fresh_lines)
    Array(existing).reject { |line| line.to_s.match?(EVIDENCE_RE) } + Array(fresh_lines)
  end

  # Freshness of one lane against `fingerprint`: :fresh (a tag matches the current
  # fingerprint), :stale (tagged, but every tag is for a different fingerprint),
  # or :missing (no tag for this lane at all).
  def lane_status(checks, lane, fingerprint)
    seen = Array(checks).each_with_object([]) do |line, values|
      fp = extract_fingerprint(line, lane)
      values << fp if fp
    end
    return :missing if seen.empty?

    seen.include?(fingerprint) ? :fresh : :stale
  end

  # The fingerprint embedded in a "[lane@<fp>] ..." checks_run line, or nil. The
  # @<fp> is what distinguishes this from a plain "[lane]" tier tag, so it never
  # collides with tier_satisfied?.
  def extract_fingerprint(line, lane)
    m = line.to_s.match(/\A\s*\[\s*#{Regexp.escape(lane)}\s*@\s*([0-9a-f]{7,64})\s*[\]:]/i)
    m && m[1].downcase
  end

  # Every DISTINCT fingerprint recorded for `lane` in `checks` (in order). Feeds
  # the STALE delta dor-check prints — the recorded "[lane@<fp>]" fingerprint(s)
  # vs the current tree hash — so a stale refusal shows WHY (which code it was
  # certified for) instead of an opaque "STALE".
  def recorded_fingerprints(checks, lane)
    Array(checks).each_with_object([]) do |line, values|
      fp = extract_fingerprint(line, lane)
      values << fp if fp
    end.uniq
  end

  # A recorded, sanctioned bypass: "[full-suite-bypass] <reason>" with a non-empty
  # reason. Returns the reason string or nil. Like the post_deploy "none" hatch,
  # the bypass is an explicit RECORD (it lives in checks_run, prints loud, shows in
  # the verdict) — not a silent skip and not a forged green.
  def bypass_reason(checks)
    Array(checks).each do |line|
      m = line.to_s.match(/\A\s*\[\s*#{Regexp.escape(BYPASS_TAG)}\s*[\]:]\s*(.+\S)/i)
      return m[1].strip if m
    end
    nil
  end

  # The whole verdict dor-check needs. Order of precedence:
  #   1. a recorded bypass wins (ok, but loudly flagged);
  #   2. an injected status (tests only — DOR_CHECK_SUITE_EVIDENCE) short-circuits
  #      the git+tag work so the gate logic can be exercised without a real run;
  #   3. otherwise recompute the fingerprint and grade both lanes.
  # Returns a Hash: { ok:, bypass:, verifiable:, fingerprint:, lanes: { ... } }.
  def evaluate(checks:, root:, injected: nil)
    reason = bypass_reason(checks)
    return verdict(ok: true, bypass: reason) if reason

    return injected_verdict(injected) if injected && !injected.empty?

    fp = fingerprint(root)
    return verdict(ok: false, verifiable: false) if fp.nil?

    lanes = LANES.to_h { |lane| [lane, lane_status(checks, lane, fp)] }
    recorded = LANES.to_h { |lane| [lane, recorded_fingerprints(checks, lane)] }
    verdict(ok: lanes.values.all?(:fresh), fingerprint: fp, lanes: lanes, recorded: recorded)
  end

  # --- internals -----------------------------------------------------------

  def verdict(ok:, bypass: nil, verifiable: true, fingerprint: nil, lanes: nil, recorded: nil)
    lanes ||= LANES.to_h { |lane| [lane, ok ? :fresh : :missing] }
    { ok: ok, bypass: bypass, verifiable: verifiable, fingerprint: fingerprint, lanes: lanes, recorded: recorded || {} }
  end

  # Map a DOR_CHECK_SUITE_EVIDENCE token to a verdict (test seam only). Tokens:
  # ok | missing | stale | tests_stale | rubocop_stale | unverifiable.
  def injected_verdict(token)
    case token
    when "ok"            then verdict(ok: true)
    when "unverifiable"  then verdict(ok: false, verifiable: false)
    when "stale"         then verdict(ok: false, lanes: { TEST_LANE => :stale, RUBOCOP_LANE => :stale })
    when "tests_stale"   then verdict(ok: false, lanes: { TEST_LANE => :stale, RUBOCOP_LANE => :fresh })
    when "rubocop_stale" then verdict(ok: false, lanes: { TEST_LANE => :fresh, RUBOCOP_LANE => :stale })
    else verdict(ok: false) # "missing" and any unknown token → both missing
    end
  end

  def capture(argv, env: {})
    IO.popen([env, *argv], err: File::NULL, &:read).to_s
  rescue SystemCallError
    ""
  end

  # Run a command for its exit status only (stdout/stderr discarded); true on a
  # clean exit. Used to stage into the throwaway index without leaking output.
  def run(argv, env: {})
    system(env, *argv, out: File::NULL, err: File::NULL)
  rescue SystemCallError
    false
  end
end
