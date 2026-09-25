# frozen_string_literal: true

# CertEvidence — the MACHINE-OWNED namespace inside a task's devops.checks_run.
#
# checks_run holds two kinds of line, written by two different hands:
#
#   [unit] bin/rails test test/models/task_test.rb      ← AUTHOR-owned (tier tags,
#   [integration] bin/rails test test/controllers          prose)
#
#   [control@<fp>:<repo>] NECESSARY — replayed test/models/a_test.rb   ← MACHINE-owned
#                                                                        (bin/control-check)
#
# The `@<fingerprint>` is what separates the two namespaces: a tier tag is a bare
# `[lane]`, evidence is `[lane@<git tree hash>]`. The optional `:<repo>` suffix
# scopes the line to the repo whose tree was hashed. bin/dor-check grades the
# control line against the task tree's fingerprint (bin/lib/tree_fingerprint.rb).
#
# ONE LANE IS LEFT. Until DevOps v3 phase 2b this namespace also carried the local
# cert receipts (the full-suite, rubocop, fast-cert and cert-deferred lanes) and
# the full-suite-bypass author hatch. The PR's settled
# green GitHub CI is now the only suite evidence bin/dor-check reads, so the
# writers that stamped those lines are gone and the lines are author prose to
# this module. What stays is the `test-only` shape's executed CONTROL, which
# nothing in CI can produce: bin/control-check replays the pre-change tests
# against current code and records what it saw.
#
# WHY THE WRITE RULE EXISTS (#preserve). `bin/task update <slug> --checks "…"`
# REPLACES the whole checks_run array. A builder who recorded the tier-tagged test
# plan AFTER running the control silently destroyed the control stamp, and the
# gate then reported it MISSING on code that was just replayed — a false negative
# whose only visible remedy was to hand-write the line, i.e. forge it. So a writer
# may supersede only the NAMESPACE it supplies lines for: an author `--checks`
# update carries every `[control@fp]` line forward; a pure-evidence write (only
# `[lane@fp]` lines, what bin/control-check sends) carries the author's tier tags
# forward. Enforced at BOTH ends — bin/task's PATCH body (build_devops) and the
# board funnel every writer passes through (Task#preserve_cert_evidence).
#
# THE REPO DIMENSION. Each (lane, repo) pair is its own namespace, so a task naming
# two repos holds a stamp for EACH. An UNSCOPED line (`[control@fp]`, no suffix)
# is its own namespace too, never superseded by a scoped write — its repo is
# unknowable, and freshness still demands an exact tree-hash match, so a leftover
# unscoped line can only fail to match, never falsely match.
module CertEvidence
  # The `test-only` shape's EXECUTED control (bin/control-check): the pre-change
  # version of the changed test files, replayed against current production code.
  CONTROL_LANE = "control"
  # Every fingerprint-bound lane — the whole machine-owned namespace.
  EVIDENCE_LANES = [CONTROL_LANE].freeze

  module_function

  # The checks_run line a lane records, embedding the fingerprint and — when the
  # writer knows which repo it stood in — the REPO SCOPE. `repo` is derived from the
  # root that was actually hashed (TaskTree.repo_of_checkout), never from the task
  # record. A blank repo writes the unscoped line, so a caller that cannot name its
  # repo degrades instead of lying.
  def evidence_line(lane, fingerprint, detail, repo: nil)
    scope = repo.to_s.strip
    tag = scope.empty? ? "#{lane}@#{fingerprint}" : "#{lane}@#{fingerprint}:#{scope}"
    "[#{tag}] #{detail}"
  end

  # Pattern for a recorded evidence line of the given lanes, at the start of a
  # checks_run line. The `@` is required — a bare "[unit]" tier tag never matches.
  def evidence_re(lanes)
    /\A\s*\[\s*(?:#{Array(lanes).map { |l| Regexp.escape(l) }.join("|")})\s*@/i
  end

  EVIDENCE_RE = evidence_re(EVIDENCE_LANES)

  # The fingerprint embedded in a "[lane@<fp>] …" line, or nil.
  def extract_fingerprint(line, lane)
    m = line.to_s.match(/\A\s*\[\s*#{Regexp.escape(lane)}\s*@\s*([0-9a-f]{7,64})\s*[\]:]/i)
    m && m[1].downcase
  end

  # Freshness of one lane against `fingerprint`: :fresh (a stamp matches the
  # current fingerprint), :stale (stamped, but every stamp is for a different
  # fingerprint), or :missing (no stamp for this lane at all). `repo` narrows the
  # read to the lines that answer for ONE repo (scoped to it, plus the unscoped
  # ones); nil reads every line.
  def lane_status(checks, lane, fingerprint, repo: nil)
    seen = Array(checks).each_with_object([]) do |line, values|
      next unless scoped_to?(line, repo)

      fp = extract_fingerprint(line, lane)
      values << fp if fp
    end
    return :missing if seen.empty?

    seen.include?(fingerprint) ? :fresh : :stale
  end

  # The evidence lane a line belongs to, or nil when the line is author-owned.
  #
  # Keyed on the `[lane@` PREFIX — the same predicate EVIDENCE_RE uses — not on a
  # well-formed fingerprint. Membership of the machine-owned namespace is about the
  # SHAPE of the line; whether the embedded fingerprint is a real tree hash that
  # grades :fresh is bin/dor-check's question (#extract_fingerprint stays strict).
  def lane_of(line)
    EVIDENCE_LANES.find { |lane| line.to_s.match?(evidence_re([lane])) }
  end

  # The REPO an evidence line is scoped to ("[lane@<fp>:<repo>]"), or nil for the
  # unscoped form. Lenient in the same direction as #lane_of.
  def repo_of(line)
    m = line.to_s.match(/\A\s*\[\s*[^\[\]@\s]+\s*@[^\]:]*:\s*([^\]\s]+)\s*\]/)
    m && m[1]
  end

  # The NAMESPACE a line belongs to — [lane, repo] for machine-owned evidence (repo
  # nil on the unscoped form), or nil when the line is author-owned. The key
  # #preserve supersedes on.
  def namespace_of(line)
    lane = lane_of(line)
    lane && [lane, repo_of(line)]
  end

  def namespaces_addressed(lines)
    Array(lines).filter_map { |line| namespace_of(line) }.uniq
  end

  # Does this line's evidence answer for `repo`? An UNSCOPED line answers for ANY
  # repo, and so does any line when the reader names no repo. A SCOPED line answers
  # only for its own, compared on the bare slug, case-insensitively.
  def scoped_to?(line, repo)
    scope = repo_of(line)
    return true if scope.nil? || repo.to_s.strip.empty?

    same_repo?(scope, repo)
  end

  def same_repo?(left, right)
    left.to_s.split("/").last.to_s.casecmp?(right.to_s.split("/").last.to_s)
  end

  # THE WRITE RULE. `incoming` is the list the caller wants stored; `prior` is
  # what is stored now. Every evidence line whose NAMESPACE the caller did NOT
  # address is carried over (appended after the caller's lines — evidence reads
  # last). A PURE-EVIDENCE write — every incoming line a `[lane@fp]` line — supplies
  # no author line, so it may not supersede the author namespace: the prior tier
  # tags and prose are carried through, ahead of the evidence. An author write (any
  # non-evidence line present) still REPLACES the author namespace wholesale — the
  # documented `--checks` contract — and an explicitly EMPTY incoming list keeps its
  # meaning as a deliberate author-namespace clear.
  #
  # WHICH NAMESPACE A WRITE BELONGS TO IS INFERRED FROM CONTENT SHAPE, because the
  # wire carries a list of strings and no intent flag. A MIXED write (evidence PLUS
  # one unparseable line) counts as an author write. That is correct for a human
  # `--checks` update carrying a hand-copied stamp, and a footgun for a writer that
  # emits a stray note beside its evidence — so bin/control-check emits only
  # #evidence_line output, which #lane_of always parses (asserted in
  # test/lib/cert_evidence_test.rb).
  def preserve(prior:, incoming:)
    incoming = Array(incoming).map(&:to_s)
    prior = Array(prior).map(&:to_s)
    addressed = namespaces_addressed(incoming)
    carried = prior.select do |line|
      ns = namespace_of(line)
      ns && !addressed.include?(ns)
    end
    if incoming.any? && incoming.all? { |line| lane_of(line) }
      return prior.reject { |line| lane_of(line) } + incoming + carried
    end

    incoming + carried
  end
end
