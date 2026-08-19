# frozen_string_literal: true

# SeamReconcile — the anomaly decision for work that is FURTHER ALONG THAN ITS
# STAGE SAYS, and which no SOP currently looks backward to find.
#
# WHY THIS FILE EXISTS
#
# The DevOps cycle is four SOPs meeting at four seams. Each SOP asserts its own
# exit and trusts its inbound seam, so when a step dies between the two — a
# killed `bin/ship`, an armed merge whose TTL lapsed, a merge that landed while
# its stamp did not — the work strands in a state that READS like an earlier one.
# Nothing alerts anyone, because "further along than the board says" is invisible
# to a query that only reads the board.
#
# The 2026-08-18 session produced all three live:
#   · two `bin/ship` runs and a sweep were killed mid-flight by the harness;
#   · two reviews ended with a merge ARMED rather than landed;
#   · `bin/review-autopilot list --all` already carried `refused` rows
#     ("Merge already in progress", a bare 405) that nothing reads.
#
# THE CONTRACT THIS ENCODES — producer proves, consumer repairs. Each SOP heals
# ONLY its inbound seam (so no SOP owns the whole state graph), and the policy is
# fixed: REPAIR the deterministic anomalies, REPORT the judgment ones, NEVER
# BLOCK. Blocking is wrong for the same reason the sweep's accepted-RED guard is
# right — that guard refuses ONE irreversible act on specific evidence, whereas a
# blanket "board must be clean" precondition lets a single stale anomaly wedge an
# entire lane.
#
# This module is the PURE half, exactly like StaleCheck: no git, no network, no
# board writes. The caller resolves the evidence and injects it, so the decision
# is unit-testable without a repo, a PR, or a session.
module SeamReconcile
  # A task in one of these stages is out of scope here: its work has reached or
  # left the integration line, so "ahead of its stage" is expected. (The
  # ship→archive seam — a `shipped` task whose `main` never moved for one of its
  # named repos — needs per-repo evidence and is deliberately NOT modelled yet.)
  TERMINAL_STAGES = %w[shipped archived].freeze

  # Which anomalies each CONSUMING SOP is accountable for. The key is the SOP
  # name from the registry in AGENTS.md, so `--seam pr-review` reads as "heal the
  # seam pr-review consumes" rather than needing a second vocabulary.
  SEAMS = {
    "pr-review" => %i[stamp_lost ship_interrupted verdict_stranded].freeze,
    "qa-release" => %i[merge_never_landed].freeze,
    "production-deploy" => %i[sweep_unfinished].freeze
  }.freeze

  # The ONLY anomaly safe to repair without a human. A PR whose state reads
  # MERGED is an OBSERVED FACT, so stamping it asserts what is already true.
  # Everything else is a judgement — most sharply `verdict_stranded`, where
  # whether a recorded merge-ready verdict survives a moved base was measured
  # WRONG once already (correct-stale-e2e-counts, 2026-08-18: base moved 23
  # commits and the PR went DIRTY under a standing merge-ready verdict).
  HEALABLE = %i[stamp_lost].freeze

  # What the operator should run, per anomaly. `%{slug}` is interpolated by
  # `repair_for`. These are prescriptions, never executed from here.
  REPAIRS = {
    stamp_lost: "bin/task merged %{slug} accepted && bin/task move %{slug} reviewed",
    ship_interrupted: "bin/ship %{slug}   # resumes; or move submitted and review it now",
    verdict_stranded: "re-read the PR head + CI: verdict holds => re-arm; base moved => re-review",
    merge_never_landed: "re-review %{slug} so pr-review lands its feat PR on accepted",
    sweep_unfinished: "read the release's latest G3 attempt: closed failed => ABORT (fix the " \
                      "cause first); still open => INTERRUPTION (re-run bin/release prepare --yes)"
  }.freeze

  # One-line explanation of what the reading MEANS, for the report.
  SUMMARIES = {
    stamp_lost: "PR is MERGED but the task never got its git-location stamp",
    ship_interrupted: "PR is open and green with no live build claim — a killed bin/ship",
    verdict_stranded: "a merge-ready verdict is recorded but no merge landed",
    merge_never_landed: "stage is reviewed with no merged stamp — review never landed the PR",
    sweep_unfinished: "merged onto release but never assembled"
  }.freeze

  # An armed autopilot action in one of these states will NEVER fire on its own,
  # so a verdict behind it is stranded. `:pending` is excluded deliberately — it
  # is still live and may yet land.
  DEAD_ARMED_STATES = %i[refused expired disarmed].freeze

  Finding = Struct.new(:slug, :anomaly, :seam, :disposition, :summary, :repair, :evidence,
                       keyword_init: true)

  module_function

  # The anomalies one seam is accountable for. Unknown seam => [].
  def anomalies_for(seam)
    SEAMS.fetch(seam.to_s, [].freeze)
  end

  def seam_for(anomaly)
    SEAMS.find { |_seam, list| list.include?(anomaly) }&.first
  end

  # :heal for the deterministic anomalies, :report for the judgement ones.
  def disposition(anomaly)
    HEALABLE.include?(anomaly) ? :heal : :report
  end

  def repair_for(anomaly, slug)
    format(REPAIRS.fetch(anomaly, ""), slug: slug)
  end

  # Classify ONE task against injected evidence. Returns a Finding or nil.
  #
  # Evidence vocabulary — every one defaults to :unknown on purpose:
  #   pr_state         :merged | :open | :closed | :none | :unknown
  #   ci               :green | :red | :pending | :none | :unknown
  #   armed            :none | :pending | :refused | :expired | :disarmed | :executed | :unknown
  #   build_claim_live true | false | :unknown
  #   merged_state     :set | :unset | :unreported  (from TaskColumnFields.state)
  #   merged_value     the column's value when :set
  #
  # THE SAFETY RULE, and it is the whole reason the defaults are :unknown — an
  # UNREADABLE fact is never a clean fact. A caller that could not reach GitHub,
  # could not read the autopilot ledger, or fetched a task from a board that does
  # not serialise `merged` must not be able to trigger a heal by omission. This
  # mirrors the sweep's stale-tree gate ("a failed read is not a clean read") and
  # TaskColumnFields' UNREPORTED state, which exists because conflating "empty"
  # with "not reported" once produced a false persistence incident.
  def classify(task, pr_state: :unknown, ci: :unknown, armed: :unknown,
               build_claim_live: :unknown, merged_state: :unreported, merged_value: nil)
    stage = task["stage"].to_s
    slug = task["slug"].to_s
    return nil if slug.empty? || TERMINAL_STAGES.include?(stage)

    anomaly, evidence =
      case stage
      when "building" then building_anomaly(pr_state, ci, build_claim_live)
      when "submitted" then submitted_anomaly(pr_state, armed, merged_state)
      when "reviewed" then reviewed_anomaly(merged_state, merged_value)
      end
    return nil unless anomaly

    finding(slug, anomaly, evidence)
  end

  # Classify many, keeping only the anomalies the named seam owns. `evidence` is
  # a hash keyed by slug; a task with no entry is classified on defaults alone,
  # which by the safety rule above can only ever yield nil or a :report.
  def scan(tasks, seam:, evidence: {})
    owned = anomalies_for(seam)
    return [] if owned.empty?

    Array(tasks).filter_map do |task|
      found = classify(task, **(evidence[task["slug"].to_s] || {}))
      found if found && owned.include?(found.anomaly)
    end
  end

  # --- per-stage decisions ----------------------------------------------------

  # A killed `bin/ship`: the PR is open and green, but the task never reached
  # `submitted` — and `bin/task claim-next-review` only pops `submitted`, so
  # review CANNOT see it. It is NOT healed automatically: `bin/ship` also
  # certifies, records checks_run and runs dor-check, none of which a bare stage
  # move would do.
  def building_anomaly(pr_state, ci, build_claim_live)
    return nil unless pr_state == :open && ci == :green && build_claim_live == false

    [:ship_interrupted, { pr: pr_state, ci: ci, build_claim: "expired" }]
  end

  def submitted_anomaly(pr_state, armed, merged_state)
    if pr_state == :merged && merged_state == :unset
      [:stamp_lost, { pr: pr_state, merged: merged_state }]
    elsif pr_state == :open && DEAD_ARMED_STATES.include?(armed)
      [:verdict_stranded, { pr: pr_state, armed: armed }]
    end
  end

  # `reviewed` with no stamp is the HELD anomaly the sweep already warns about;
  # `reviewed` + merged:"release" is the unfinished-RC reading. The latter is
  # deliberately NOT healed: an INTERRUPTED sweep and an ABORTED one leave the
  # IDENTICAL board state, and only the release's G3 attempt separates them.
  def reviewed_anomaly(merged_state, merged_value)
    return nil unless merged_state == :set || merged_state == :unset
    return [:merge_never_landed, { merged: :unset }] if merged_state == :unset
    return [:sweep_unfinished, { merged: merged_value.to_s }] if merged_value.to_s == "release"

    nil
  end

  def finding(slug, anomaly, evidence)
    Finding.new(
      slug: slug,
      anomaly: anomaly,
      seam: seam_for(anomaly),
      disposition: disposition(anomaly),
      summary: SUMMARIES.fetch(anomaly, ""),
      repair: repair_for(anomaly, slug),
      evidence: evidence || {}
    )
  end
end
