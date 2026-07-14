# frozen_string_literal: true

# bin/lib/full_suite_gate.rb — the fingerprint-bound certification evidence contract.
#
# Shared by the writers and the reader so the format lives in ONE place:
#   * bin/full-suite-check WRITES full-cert evidence (FULL suite + FULL rubocop).
#   * bin/fast-check       WRITES fast-cert evidence (diff-mapped tests + core
#                          spine + rubocop on changed files — the G1 fast cert;
#                          bin/dor-check accepts it only alongside a GREEN GitHub
#                          CI, which runs the full suite as the net).
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
# Evidence is recorded as fingerprint-tagged checks_run lines the runners stamp:
#   [full-suite@<fp>] bin/rails test (NNN runs, 0 failures)   (bin/full-suite-check)
#   [rubocop@<fp>]    bin/rubocop (clean)                     (bin/full-suite-check)
#   [fast-cert@<fp>]  mapped+spine tests + scoped rubocop     (bin/fast-check)
# dor-check credits a lane only when a line is tagged for it AND the embedded
# fingerprint equals the local recomputed one. Hand-writing a green tag is not
# defended against (honor system — "Trust over guardrails"); the point is to make
# the honest path one command and to CATCH the easy mistake (touched-files subset
# + a stale tag), which a content fingerprint does deterministically.
#
# The evidence LINE FORMAT and the write rule that keeps an author's `--checks`
# update from wiping a cert live in lib/cert_evidence.rb — shared, because the
# board (app/models/task.rb) enforces the same rule server-side and Rails can
# autoload lib/ but not bin/lib/. This module owns the parts that need git and a
# working tree: the fingerprint, the freshness grading, the bypass record.
require "tmpdir"
require_relative "../../lib/cert_evidence"

module FullSuiteGate
  TEST_LANE = CertEvidence::TEST_LANE
  RUBOCOP_LANE = CertEvidence::RUBOCOP_LANE
  FAST_LANE = CertEvidence::FAST_LANE
  BYPASS_TAG = "full-suite-bypass"
  # The FULL-cert lanes — what evaluate's `ok` means (full suite + full rubocop
  # both fresh). The fast lane is deliberately NOT part of `ok`: fast-cert
  # evidence only satisfies the merge gate when dor-check ALSO sees a green
  # GitHub CI, and that pairing is dor-check's call, not this module's.
  LANES = CertEvidence::LANES
  # Every fingerprint-bound evidence lane (for merge/replace + grading).
  EVIDENCE_LANES = CertEvidence::EVIDENCE_LANES
  EVIDENCE_RE = CertEvidence::EVIDENCE_RE

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

  # Tree hash of a COMMITTED git ref (e.g. origin/feat/<slug>) within `root`, or
  # nil when the ref can't be resolved (unfetched branch / bad ref). A git tree
  # hash is purely content-addressed, so a branch's committed `^{tree}` equals the
  # working-tree fingerprint the builder certified before committing + pushing
  # (commit → cert is stable across the boundary — the whole anti-stale design).
  # That lets the REVIEW gate-zero grade the builder's cert from a checkout that
  # ISN'T on the branch — the primary checkout the reviewer runs from is on
  # release/main, so `fingerprint(root)` there reads a DIFFERENT tree and the cert
  # false-reads STALE; this reads the branch tree instead. `--verify --quiet`
  # emits nothing on stdout and exits non-zero on a bad ref, so capture → "".
  def fingerprint_of_ref(root, ref)
    return nil if ref.to_s.strip.empty?

    tree = capture(["git", "-C", root.to_s, "rev-parse", "--verify", "--quiet", "#{ref}^{tree}"]).strip
    tree.empty? ? nil : tree
  end

  # --- the evidence-namespace contract (lib/cert_evidence.rb) ---------------
  # Delegated, not re-implemented: the board enforces the same rule on every
  # write, so the format has exactly one definition.

  # The checks_run line a passing lane records, embedding the fingerprint.
  def evidence_line(lane, fingerprint, detail)
    CertEvidence.evidence_line(lane, fingerprint, detail)
  end

  # Pattern for a recorded evidence line of the given lanes (e.g.
  # "[full-suite@..]" / "[rubocop@..]" / "[fast-cert@..]"), at the start of a
  # checks_run line.
  def evidence_re(lanes)
    CertEvidence.evidence_re(lanes)
  end

  # Merge fresh evidence lines into an existing checks_run, REPLACING prior
  # evidence for the lanes being stamped (so re-runs supersede rather than
  # accumulate) while PRESERVING tier tags ("[unit] ..."), bypass records, and
  # every OTHER lane's evidence. Defaults to exactly the lanes `fresh_lines`
  # carries — you supersede what you supply, which is the same rule the board
  # applies to every writer (CertEvidence.preserve). A full cert therefore leaves
  # a prior fast-cert line in place rather than deleting it: it is inert once the
  # full lanes are fresh (evaluate's `ok` reads LANES only), and letting a writer
  # delete a lane it did not run is precisely the destruction this gate now
  # refuses to allow.
  def merge_evidence(existing, fresh_lines, lanes: nil)
    CertEvidence.merge_evidence(existing, fresh_lines, lanes: lanes)
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
    CertEvidence.extract_fingerprint(line, lane)
  end

  # Every fingerprint RECORDED for `lane` (the "[lane@<fp>]" tags), de-duped, in
  # order. lane_status collapses these to :fresh/:stale/:missing — a verdict, but
  # not an EXPLANATION. "STALE" alone reads as "you edited since certifying" even
  # when the real cause is that the gate is standing in the WRONG TREE, and the two
  # want opposite fixes (re-certify vs. re-root). Surfacing what the evidence was
  # certified FOR lets dor-check print the DELTA — certified @abc, HEAD is now @def
  # — so the cause is legible instead of guessed at.
  def recorded_fingerprints(checks, lane)
    Array(checks).filter_map { |line| extract_fingerprint(line, lane) }.uniq
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
  #   3. otherwise recompute the fingerprint and grade every evidence lane.
  # Returns a Hash: { ok:, bypass:, verifiable:, fingerprint:, lanes:, recorded: }.
  # `ok` means the FULL cert is satisfied (LANES fresh). lanes[FAST_LANE] carries
  # the fast-cert lane's freshness so dor-check can pair a fresh fast cert with a
  # green GitHub CI — this module grades evidence; it never reads CI. `recorded`
  # carries each lane's RECORDED fingerprints (what the evidence was certified for)
  # so a STALE verdict can be reported as a delta against `fingerprint` rather than
  # as an opaque label.
  #
  # `fingerprint_override` (the review gate-zero seam): grade against THIS tree
  # hash instead of recomputing `fingerprint(root)`. The reviewer runs from a
  # primary checkout that isn't on the task branch, so the working-tree hash there
  # is the wrong tree — dor-check passes the branch's committed tree (via
  # fingerprint_of_ref) so the cert grades against the code the builder certified.
  # nil (the default / a branch that couldn't be resolved) → recompute from root,
  # the builder-side behavior.
  def evaluate(checks:, root:, injected: nil, fingerprint_override: nil)
    reason = bypass_reason(checks)
    return verdict(ok: true, bypass: reason) if reason

    return injected_verdict(injected) if injected && !injected.empty?

    fp = fingerprint_override || fingerprint(root)
    return verdict(ok: false, verifiable: false) if fp.nil?

    lanes = EVIDENCE_LANES.to_h { |lane| [lane, lane_status(checks, lane, fp)] }
    recorded = EVIDENCE_LANES.to_h { |lane| [lane, recorded_fingerprints(checks, lane)] }
    verdict(ok: LANES.all? { |lane| lanes[lane] == :fresh }, fingerprint: fp, lanes: lanes, recorded: recorded)
  end

  # --- internals -----------------------------------------------------------

  def verdict(ok:, bypass: nil, verifiable: true, fingerprint: nil, lanes: nil, recorded: nil)
    lanes ||= EVIDENCE_LANES.to_h { |lane| [lane, ok ? :fresh : :missing] }
    # The bypass/injected/unverifiable paths never read the checks, so they carry no
    # recorded fingerprints — an EMPTY list per lane, not a missing key, so callers
    # can always index it. dor-check falls back to the plain STALE wording there.
    recorded ||= EVIDENCE_LANES.to_h { |lane| [lane, []] }
    { ok: ok, bypass: bypass, verifiable: verifiable, fingerprint: fingerprint, lanes: lanes,
      recorded: recorded }
  end

  # Map a DOR_CHECK_SUITE_EVIDENCE token to a verdict (test seam only). Tokens:
  # ok | missing | stale | tests_stale | rubocop_stale | unverifiable |
  # fast_fresh | fast_stale (fast-cert evidence with NO full-cert evidence).
  def injected_verdict(token)
    case token
    when "ok"            then verdict(ok: true)
    when "unverifiable"  then verdict(ok: false, verifiable: false)
    when "stale"         then verdict(ok: false, lanes: { TEST_LANE => :stale, RUBOCOP_LANE => :stale, FAST_LANE => :missing })
    when "tests_stale"   then verdict(ok: false, lanes: { TEST_LANE => :stale, RUBOCOP_LANE => :fresh, FAST_LANE => :missing })
    when "rubocop_stale" then verdict(ok: false, lanes: { TEST_LANE => :fresh, RUBOCOP_LANE => :stale, FAST_LANE => :missing })
    when "fast_fresh"    then verdict(ok: false, lanes: { TEST_LANE => :missing, RUBOCOP_LANE => :missing, FAST_LANE => :fresh })
    when "fast_stale"    then verdict(ok: false, lanes: { TEST_LANE => :missing, RUBOCOP_LANE => :missing, FAST_LANE => :stale })
    else verdict(ok: false) # "missing" and any unknown token → all lanes missing
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
