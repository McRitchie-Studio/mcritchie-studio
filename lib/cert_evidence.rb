# frozen_string_literal: true

# CertEvidence — the MACHINE-OWNED namespace inside a task's devops.checks_run.
#
# checks_run holds two kinds of line, written by two different hands:
#
#   [unit] bin/rails test test/models/task_test.rb      ← AUTHOR-owned (tier tags,
#   [integration] bin/rails test test/controllers          bypass records, prose)
#   [full-suite-bypass] CI outage, ran locally
#
#   [full-suite@<fp>] bin/rails test (782 runs, 0 failures)   ← MACHINE-owned
#   [rubocop@<fp>]    bin/rubocop (clean)                        CERT EVIDENCE
#   [fast-cert@<fp>]  mapped+spine tests + scoped rubocop        (bin/fast-check,
#                                                                bin/full-suite-check)
#
# The `@<fingerprint>` is what separates the two namespaces: a tier tag is a bare
# `[lane]`, evidence is `[lane@<git tree hash>]`. bin/dor-check reads ONLY the
# evidence lines to decide whether the code is certified (see
# bin/lib/full_suite_gate.rb for the fingerprint + grading half).
#
# WHY THIS MODULE EXISTS (bug, 2026-07-12 — hit twice in one session, ~8 minutes
# burned each time): `bin/task update <slug> --checks "…"` REPLACED the whole
# checks_run array. An agent that recorded its tier-tagged test plan AFTER
# certifying silently DESTROYED its own cert evidence, and bin/dor-check then
# reported "full-suite: MISSING (never certified for this exact code)" on code
# that WAS just certified — a FALSE NEGATIVE in the G1 cert gate, whose only
# visible remedy was to burn another suite run (or, worse, to hand-write an
# evidence line and forge the cert). The check-writers already protected the
# author's lines ("tier tags preserved"); the author's --checks wiped the
# machine's. This module makes that asymmetry symmetric.
#
# THE WRITE RULE (#preserve) — one sentence: a writer may only supersede a
# NAMESPACE it supplies lines for — each evidence LANE is a namespace, and the
# author's lines (tier tags, bypasses, prose) are one namespace too. So:
#   * an author `--checks` update (tier tags only, no `[lane@fp]` lines) can
#     never drop a cert — every lane is carried over;
#   * a cert writer that just ran a lane green stamps that lane and replaces its
#     own prior line (no stale accumulation), leaving the other lanes intact;
#   * a PURE-EVIDENCE write (only `[lane@fp]` lines — what the cert writers send
#     when their own read of checks_run was stale or empty) can never drop the
#     author's tier tags — the author namespace is carried over (reverse
#     regression 2026-07-20: fast-check's read missed freshly recorded tier
#     lines and its evidence write superseded the author namespace with nothing,
#     while claiming "tier tags preserved").
# Destroying a cert therefore REQUIRES writing a fingerprint-bound line for that
# lane by hand — i.e. deliberately forging a certification, not fat-fingering an
# ordinary `--checks` update. Ordering ("record --checks BEFORE you certify") is
# no longer load-bearing: both orders are safe.
#
# Enforced at BOTH ends, so no caller inherits the old behavior:
#   * bin/task     — build_devops carries evidence forward into the PATCH body
#                    (protects agents immediately, even against an older board).
#   * Task#preserve_cert_evidence — the board funnel every writer passes through
#                    (bin/task, the board UI form, a raw API PATCH, the console).
#
# NOT protected, deliberately: `[full-suite-bypass] <why>` is an AUTHOR record —
# a human's conscious, loud skip. Force-preserving it would make a bypass
# impossible to withdraw, so it stays author-owned and removable.
module CertEvidence
  TEST_LANE = "full-suite"
  RUBOCOP_LANE = "rubocop"
  FAST_LANE = "fast-cert"
  # The FULL-cert lanes (what "certified" means: full suite + full rubocop, both
  # fresh). The fast lane is separate — it only satisfies the gate paired with a
  # green GitHub CI, which is bin/dor-check's call.
  LANES = [TEST_LANE, RUBOCOP_LANE].freeze
  # Every fingerprint-bound lane — the whole machine-owned namespace.
  EVIDENCE_LANES = (LANES + [FAST_LANE]).freeze

  module_function

  # The checks_run line a passing lane records, embedding the fingerprint.
  def evidence_line(lane, fingerprint, detail)
    "[#{lane}@#{fingerprint}] #{detail}"
  end

  # Pattern for a recorded evidence line of the given lanes, at the start of a
  # checks_run line. The `@` is required — a bare "[unit]" tier tag or a
  # "[full-suite-bypass]" record never matches.
  def evidence_re(lanes)
    /\A\s*\[\s*(?:#{Array(lanes).map { |l| Regexp.escape(l) }.join("|")})\s*@/i
  end

  EVIDENCE_RE = evidence_re(EVIDENCE_LANES)

  # The fingerprint embedded in a "[lane@<fp>] …" line, or nil.
  def extract_fingerprint(line, lane)
    m = line.to_s.match(/\A\s*\[\s*#{Regexp.escape(lane)}\s*@\s*([0-9a-f]{7,64})\s*[\]:]/i)
    m && m[1].downcase
  end

  # The evidence lane a line belongs to ("full-suite" / "rubocop" / "fast-cert"),
  # or nil when the line is author-owned (a tier tag, a bypass, prose).
  #
  # Keyed on the `[lane@` PREFIX — the same predicate EVIDENCE_RE uses — not on a
  # well-formed fingerprint. Membership of the machine-owned namespace is about
  # the SHAPE of the line; whether the embedded fingerprint is a real tree hash
  # that grades :fresh is bin/dor-check's question (#extract_fingerprint, which
  # stays strict). Splitting the two predicates would let a malformed evidence
  # line be neither superseded nor recognized, and it would leave the writers'
  # merge disagreeing with the board's preserve.
  def lane_of(line)
    EVIDENCE_LANES.find { |lane| line.to_s.match?(evidence_re([lane])) }
  end

  # The lanes a list of lines carries evidence for.
  def lanes_addressed(lines)
    Array(lines).filter_map { |line| lane_of(line) }.uniq
  end

  # THE WRITE RULE. `incoming` is the list the caller wants stored; `prior` is
  # what's stored now. Every evidence line whose lane the caller did NOT address
  # is carried over (appended, after the caller's lines — evidence reads last,
  # the order the cert writers already stamp).
  #
  # The AUTHOR namespace obeys the same rule (reverse regression, 2026-07-20 —
  # fast-check-preserves-checks): a PURE-EVIDENCE write — every incoming line a
  # `[lane@fp]` evidence line, which is what bin/fast-check / bin/full-suite-check
  # send when their own read of checks_run came back stale or empty — supplies no
  # author line, so it may not supersede the author namespace: the prior tier
  # tags, bypass records, and prose are carried through, ahead of the evidence.
  # An author write (any non-evidence line present) still REPLACES the author
  # namespace wholesale — the documented `--checks` contract — and an explicitly
  # EMPTY incoming list keeps its meaning as a deliberate author-namespace clear.
  #
  # WHICH NAMESPACE A WRITE BELONGS TO IS INFERRED FROM CONTENT SHAPE, because the
  # wire carries a list of strings and no intent flag (bin/task's `--checks` → the
  # API → this rule). So the protection is exactly as good as the writers' output:
  # a MIXED write (evidence PLUS one unparseable line) counts as an author write
  # and replaces the author namespace with just that line. That is correct for a
  # human `--checks` update carrying a hand-copied evidence line, and it is a
  # FOOTGUN for a cert that ever emits a stray note beside its evidence.
  # The coupling that makes it safe — every production evidence writer emits only
  # #evidence_line output, which #lane_of always parses (it is prefix-keyed, so
  # even a malformed fingerprint still classifies as evidence) — is ASSERTED in
  # test/lib/cert_evidence_test.rb, not merely believed. Giving the write an
  # explicit namespace would need an intent channel threaded through CLI → API →
  # model; worth doing, but it is a contract change rather than this bug's fix.
  def preserve(prior:, incoming:)
    incoming = Array(incoming).map(&:to_s)
    prior = Array(prior).map(&:to_s)
    addressed = lanes_addressed(incoming)
    carried = prior.select do |line|
      lane = lane_of(line)
      lane && !addressed.include?(lane)
    end
    if incoming.any? && incoming.all? { |line| lane_of(line) }
      return prior.reject { |line| lane_of(line) } + incoming + carried
    end

    incoming + carried
  end
end
