# frozen_string_literal: true

# An ARMED MERGE — one reviewer's already-formed, already-recorded merge-ready
# verdict, written down so it can finish executing after that reviewer's process
# is gone.
#
# THE PROBLEM IT SOLVES (measured seven times on the night of 2026-08-10/11): a
# reviewer completes its review, records a correct merge-ready verdict, waits on a
# CI lane, and its process ends before it can merge. Nothing was wrong with the
# review. The DECISION was already durable — a scout-report activity on the task —
# and only the EXECUTION was lost. A human was the safety net all seven times; one
# reviewer stopped with 3 of 4 lanes green and the fourth settled eighty seconds
# later. At forty concurrent tasks nobody is awake to be that safety net.
#
# WHAT IT IS NOT. This row never FORMS a verdict, and neither does anything that
# reads it. It records an instruction a reviewer already gave — "merge THIS pr at
# THIS sha, on the authority of THIS recorded verdict" — and the executor either
# carries it out unchanged or refuses. Keep that line bright: any future code here
# that weighs a diff, judges CI beyond green/not-green, or decides mergeability on
# its own has turned an errand-runner into an unsupervised reviewer.
#
# TWO THINGS CAN MOVE between the verdict and the merge, and each has its own pin.
#
#   THE TREE MAY CHANGE — `head_sha`. A verdict describes a TREE, not a branch
#   name: if the head moved after the review, the recorded decision does not apply
#   to what is there now, and the action refuses rather than merging code no one
#   read. Enforced three times over — against the CI we hold, against the live PR
#   head, and by GitHub itself via the merge API's `sha` parameter.
#
#   THE VERDICT MAY CHANGE — the latest scout report. Arming binds to the task's
#   LATEST report and refuses unless it is `merge-ready`; execution re-reads it and
#   refuses if a newer, non-merge-ready report has landed since. An explicit disarm
#   was never the problem: a reviewer who changes their mind records
#   `request-changes`, and that has to be enough. See #superseding_scout_report.
#
# EVERY OTHER GUARD FAILS CLOSED TOO: only a settled GREEN acts (red, pending,
# cancelled and ABSENT check-runs all do nothing — "no checks reported" is the
# signature of a CONFLICTING PR, not a pass); an action past `expires_at` is
# dropped rather than executed late; an action with no authorising verdict is
# never created in the first place; and the DESTINATION is fixed by the action
# type rather than by the caller (see ACTION_BASE_BRANCHES).
class ReviewPendingAction < ApplicationRecord
  # The only action this table knows how to execute today. Named (rather than
  # assumed) so a second action type is an explicit addition, not a silent reuse.
  MERGE_TO_ACCEPTED = "merge_to_accepted"
  ACTIONS = [MERGE_TO_ACCEPTED].freeze

  # THE DESTINATION, made binding rather than advisory. `MERGE_TO_ACCEPTED` NAMES
  # the branch it merges into, but a free-form `base_branch` column meant the name
  # was a label on data that could say anything — and a main-based PR armed against
  # this action merged into `main` in a probe.
  #
  # That matters more than a wrong-branch merge. The entire argument for letting a
  # machine merge unattended is that the blast radius is `accepted`, with the QA
  # sweep and a separately-gated production deploy downstream. If the destination
  # is whatever the caller typed, that argument is a convention rather than a
  # structural fact. This map makes it structural: enforced as a validation on
  # every writer, refused at arm time, and re-read at fire time (rows written
  # before this constraint existed are still in the table).
  ACTION_BASE_BRANCHES = { MERGE_TO_ACCEPTED => "accepted" }.freeze

  PENDING  = "pending"
  EXECUTED = "executed"
  EXPIRED  = "expired"
  REFUSED  = "refused"
  DISARMED = "disarmed"
  STATES = [PENDING, EXECUTED, EXPIRED, REFUSED, DISARMED].freeze
  TERMINAL_STATES = (STATES - [PENDING]).freeze

  # The recorded scout-report outcome that AUTHORISES a merge. Deliberately just
  # the one: `merge-ready` is the reviewer saying "no blockers, merge it". The
  # sibling outcomes are not authorisations — `wait-for-ci` is a deferral,
  # `request-changes` a block, `conductor-review` an escalation to a human — and
  # reading any of them as consent would be inventing a verdict.
  AUTHORISING_VERDICT = "merge-ready"

  # How long an armed merge stays executable. Long enough to cover a slow CI
  # lane (the failure this exists for settled in eighty seconds) and a queued
  # re-run, short enough that an action never executes against a world that has
  # moved on while everyone slept. Past this the action is dropped, not run.
  DEFAULT_TTL = 6.hours

  # Slug-based FK, the convention everywhere in this schema.
  belongs_to :task, foreign_key: :task_slug, primary_key: :slug, optional: true, inverse_of: false

  # Normalize the two columns the webhook trigger JOINs on. A settled CI run
  # names its repo as a full name ("McRitchie-Studio/mcritchie-studio") and its
  # sha in lowercase hex; an action armed with a bare repo slug or an uppercased
  # sha would simply never be found by its own trigger — invisible, not refused.
  before_validation do
    self.repo = self.class.normalize_repo(repo)
    self.head_sha = head_sha.to_s.strip.downcase.presence
    self.base_branch = base_branch.to_s.strip.presence
  end

  def self.normalize_repo(value, default_owner: Ci::ReviewGate::DEFAULT_OWNER)
    repo = value.to_s.strip
    return repo if repo.empty? || repo.include?("/")

    "#{default_owner}/#{repo}"
  end

  validates :task_slug, presence: true
  validates :repo, presence: true
  validates :head_sha, presence: true
  validates :pr_number, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :verdict, presence: true
  validates :expires_at, presence: true
  validates :action, inclusion: { in: ACTIONS }
  validates :state, inclusion: { in: STATES }
  # Scoped to writes that actually SET the destination — every create, and any
  # update that touches the column. A blanket validation looked tighter and was
  # worse: it also rejected the executor's own `settle!` on a row whose base_branch
  # predates this rule, so the one legacy row the fire-time guard exists to catch
  # could never be settled REFUSED and would retry as `pending` forever. A guard
  # that traps its own subject is not a guard.
  validate :base_branch_matches_action, if: -> { new_record? || will_save_change_to_base_branch? }

  scope :pending, -> { where(state: PENDING) }
  scope :for_head, ->(repo, sha) { where(repo: repo.to_s, head_sha: sha.to_s) }
  scope :recent_first, -> { order(created_at: :desc) }

  # Arm a merge for a task — the ONE creation path, so the authorisation check can
  # never be bypassed by a caller that builds the row itself.
  #
  # Raises Unauthorised when the task's CURRENT decision is not `merge-ready`, or
  # when the caller asks for a destination this action type may not merge into.
  # That is the "never invent a verdict" rule made structural: with no standing
  # decision there is nothing to execute, and arming would be the machine deciding
  # to merge.
  #
  # A re-arm (same task, new head after a zap) SUPERSEDES the live action rather
  # than stacking a second merge order beside it.
  class Unauthorised < StandardError; end

  def self.arm!(task:, repo:, pr_number:, head_sha:, pr_url: nil, base_branch: "accepted",
                merge_method: "merge", authorized_by: nil, now: Time.current, ttl: DEFAULT_TTL)
    refusal = arm_refusal_reason(task)
    raise Unauthorised, refusal if refusal

    # The destination is the action type's, not the caller's. Refused here (rather
    # than left to the validation) so an API caller asking for the wrong branch gets
    # a clean answer instead of a RecordInvalid surfacing as a 500.
    required_base = ACTION_BASE_BRANCHES.fetch(MERGE_TO_ACCEPTED)
    requested_base = base_branch.to_s.strip.presence || required_base
    unless requested_base == required_base
      raise Unauthorised,
            "#{MERGE_TO_ACCEPTED} may only merge into #{required_base}, not #{requested_base} — " \
            "an armed merge's blast radius is #{required_base} by construction"
    end

    verdict = authorising_verdict_for(task)

    transaction do
      # Through `settle!`, so the supersede cannot falsify a row that settled
      # between the `pending` read above and this write — an action that MERGED
      # while we were arming its replacement keeps its executed record, and the
      # re-arm proceeds because that row is no longer pending (which is also what
      # the partial unique index on live actions is measuring).
      pending.where(task_slug: task.slug).find_each do |live|
        live.settle!(state: DISARMED, reason: "superseded by a re-arm at #{head_sha}")
      end

      create!(
        task_slug:           task.slug,
        action:              MERGE_TO_ACCEPTED,
        repo:                repo.to_s,
        pr_number:           pr_number.to_i,
        pr_url:              pr_url.presence,
        base_branch:         requested_base,
        merge_method:        merge_method.presence || "merge",
        head_sha:            head_sha.to_s.strip,
        verdict:             AUTHORISING_VERDICT,
        verdict_activity_id: verdict.id,
        verdict_recorded_at: verdict.created_at,
        authorized_by:       authorized_by.presence || verdict.agent_slug.presence,
        state:               PENDING,
        expires_at:          now + ttl
      )
    end
  end

  # Every scout report on the task, newest first — a reviewer's running commentary
  # on one PR. Only the newest is a STANDING decision; the rest are history.
  def self.scout_reports_for(task)
    Activity.for_task(slug_of(task))
            .where("metadata ->> 'kind' = ?", "scout_report")
            .order(created_at: :desc, id: :desc)
  end

  # The task's CURRENT decision, whatever it says.
  def self.latest_scout_report(task)
    return nil if slug_of(task).blank?

    scout_reports_for(task).first
  end

  # The recorded decision an armed merge executes: the task's LATEST scout report,
  # and only when that latest report is `merge-ready`.
  #
  # "LATEST" is the whole of it, and it is not the same rule as "the latest
  # merge-ready one". An older `merge-ready` sitting behind a newer
  # `request-changes` is not a standing decision — it is a decision the reviewer
  # has since REVISED, and executing it would carry out an order that was
  # withdrawn. Reading past the revision to find an outcome we like is exactly the
  # "never invent a verdict" rule broken from the other end.
  def self.authorising_verdict_for(task)
    report = latest_scout_report(task)
    report if scout_outcome(report) == AUTHORISING_VERDICT
  end

  # Why this task cannot be armed right now — nil when it can. Names the report
  # that is actually standing, so an operator reading the refusal learns which
  # verdict is in the way instead of the misleading "no verdict found".
  #
  # It ASKS #authorising_verdict_for rather than re-deciding: one rule, one place.
  # The first cut re-implemented the same test here, and the mutation harness
  # caught it — loosening #authorising_verdict_for back to "any merge-ready in the
  # history" reddened nothing, because this method was quietly holding the line on
  # its own. Two copies of a rule means the copy nobody calls can rot unnoticed.
  def self.arm_refusal_reason(task)
    slug = slug_of(task)
    return "no task to arm" if slug.blank?
    return nil if authorising_verdict_for(task)

    report = latest_scout_report(task)
    if report.nil?
      return "no recorded #{AUTHORISING_VERDICT} scout report on #{slug} — " \
             "record the review verdict before arming its merge"
    end

    "the latest scout report on #{slug} is #{scout_outcome(report).presence || "unlabelled"} " \
      "(#{report.agent_slug.presence || "an agent"} at #{report.created_at.utc.iso8601}), " \
      "not #{AUTHORISING_VERDICT} — the decision has been revised since any earlier merge-ready verdict"
  end

  # The recorded outcome of a scout report ("merge-ready", "request-changes", …),
  # or "" for a nil activity or one with no outcome — never nil, so callers can
  # compare against AUTHORISING_VERDICT without a nil dance.
  def self.scout_outcome(activity)
    metadata = activity&.metadata
    metadata.is_a?(Hash) ? metadata["outcome"].to_s : ""
  end

  def self.slug_of(task)
    (task.respond_to?(:slug) ? task.slug : task).to_s
  end

  # THE WEBHOOK TRIGGER. A CI run settling names exactly one repo + head_sha, and
  # that pair selects precisely the actions pinned to that tree — so the pin does
  # double duty as the lookup key, and a settled run on any unrelated branch costs
  # one indexed miss. Called from GithubWorkflowRunIngestJob after every ingest.
  def self.trigger_for_head(repo:, head_sha:)
    repo = normalize_repo(repo)
    head_sha = head_sha.to_s.strip.downcase
    return 0 if repo.blank? || head_sha.blank?

    ids = pending.for_head(repo, head_sha).pluck(:id)
    ids.each { |id| ReviewPendingActionExecutionJob.perform_later(id) }
    ids.size
  end

  def pending?
    state == PENDING
  end

  def expired?(now: Time.current)
    expires_at.present? && expires_at <= now
  end

  # Does the authorising verdict still exist? The WITHDRAWN half of the rule —
  # the report was deleted, so there is no recorded decision left to execute.
  def verdict_recorded?
    return false if verdict_activity_id.blank?

    Activity.where(id: verdict_activity_id).exists?
  end

  # The scout report that REVISED this action's authorisation — the SUPERSEDED
  # half of the rule, and the half that was missing: this method's predecessor
  # promised a report "deleted or superseded" stopped authorising, and only ever
  # checked deleted. A reviewer could arm on a merge-ready verdict, record a
  # `request-changes` afterwards, and the armed merge still fired on green CI.
  #
  # THIS IS THE MIRROR OF THE HEAD-SHA PIN, and worth reading as a pair: the pin
  # exists because the TREE may have changed since the verdict; this exists
  # because the VERDICT may have changed since the tree. Both are re-read at fire
  # time for the same reason — both can move after arming, and the autopilot's
  # whole premise is that it carries out an ALREADY-MADE decision. A decision
  # since revised is not the decision it was authorised to carry out.
  #
  # Why revision and not just disarming: an explicit disarm already worked. But a
  # human who changes their mind records `request-changes`; nobody thinks "I must
  # disarm the robot". The guard has to cover the action people actually take.
  #
  # nil when the standing decision is still merge-ready — INCLUDING a later
  # merge-ready report from a second reviewer. That is a re-affirmation, not a
  # revision, and the primary and light reviewers each record their own.
  def superseding_scout_report
    latest = self.class.latest_scout_report(task_slug)
    return nil if latest.nil?
    return nil if self.class.scout_outcome(latest) == AUTHORISING_VERDICT

    latest
  end

  # The branch this action type is allowed to merge into, regardless of what the
  # row says. nil for an unrecognised action (the inclusion validation owns that).
  def required_base_branch
    ACTION_BASE_BRANCHES[action.to_s]
  end

  def base_branch_authorised?
    required_base_branch.nil? || base_branch.to_s == required_base_branch
  end

  # "McRitchie-Studio/mcritchie-studio" — the API path segment. The column already
  # stores the full name; this normalises a bare slug arriving from an older caller.
  def repo_nwo(default_owner: Ci::ReviewGate::DEFAULT_OWNER)
    value = repo.to_s.strip
    return value if value.include?("/")

    "#{default_owner}/#{value}"
  end

  # THE SETTLE — the one write that moves an action out of `pending`, and the only
  # place a terminal state becomes terminal. Returns true when THIS call settled
  # the row, false when it arrived at a row someone else had already settled.
  #
  # WHY A SETTLED ROW IS SACRED. This is the component that merges code when
  # nobody is watching, so its row is not a status field — it is the whole audit
  # trail, and the only account of what the machine did. A row that reads REFUSED
  # with no merge sha, for a merge that actually happened, is worse than a crash:
  # it will be read later as "the autopilot declined", and someone will re-arm or
  # merge by hand against a branch that has already moved.
  #
  # WHY A CONDITIONAL UPDATE AND NOT `return false unless pending?`. The executor
  # DELIBERATELY releases its claim lock before the GitHub round trip — holding it
  # would pin one Postgres connection per in-flight merge against a 20-connection
  # pool, the limit this ecosystem has already hit once (the board 500'd on
  # `FATAL: too many connections`). That trade is correct and stays. Its
  # consequence is that two jobs can both pass `pending?` and both arrive HERE, so
  # an in-Ruby re-check would only move the same race a few microseconds later.
  # `UPDATE … WHERE state = 'pending'` makes the test and the write ONE statement,
  # and the database arbitrates it inside the row lock: exactly one caller gets
  # rows-affected 1, every other caller gets 0 — including a future writer that
  # never read this comment.
  #
  # WHY NOT A TRIGGER. A Postgres trigger rejecting any UPDATE that moves a row
  # out of a terminal state would also cover a raw `UPDATE` typed at a console,
  # which this does not. It was rejected on evidence, not taste: this app keeps
  # `db/schema.rb` (there is no `structure.sql`), so a trigger would not survive
  # `db:schema:load` — it would exist in production and in NO test database,
  # making the strongest guard in the system the one guard nothing can prove. A
  # guard that cannot be tested is a guard that quietly rots. The conditional
  # UPDATE is enforced by the same database, on every path that goes through this
  # model, and every test can see it work.
  #
  # LOSING IS NOT AN ERROR — it is the ordinary outcome of two triggers for one
  # merge (the CI webhook and the arm's own recheck chain both fire), so this
  # returns false rather than raising. The caller's job is to REPORT the loss.
  #
  # WHAT FIRST-WRITE-WINS DOES NOT COVER, stated because a boundary nobody wrote
  # down is a boundary the next reader assumes away. If a sibling that is going to
  # REFUSE wins the race against the sibling that actually merged, the row reads
  # refused for a merge that happened — the same class of lie, from the other end.
  # It is much narrower than the defect this closes (the refusing paths are all
  # DB-only reads, and the one that reads the post-merge PR settles EXECUTED by
  # #gate_pull_request, not refused), and it is NOT closed by ranking the states:
  # "executed may overwrite refused" would put a second writer back on a settled
  # row, which is the whole thing being removed. It closes at the READING instead
  # — an executor whose merge is rejected 405/409 should re-read the PR before
  # concluding the head moved, because "already merged" and "head moved" are the
  # same HTTP answer. That is a separate defect in the refusal path, and it wants
  # its own test.
  def settle!(state:, reason: nil, merge_sha: nil, now: Time.current)
    unless TERMINAL_STATES.include?(state)
      raise ArgumentError,
            "settle! moves an action to a TERMINAL state; #{state.inspect} is not one of " \
            "#{TERMINAL_STATES.join(", ")}"
    end

    attributes = {
      state:          state,
      outcome_reason: reason.presence,
      merge_sha:      merge_sha.presence,
      updated_at:     now
    }
    attributes[:executed_at] = now if state == EXECUTED

    settled = self.class.where(id: id, state: PENDING).update_all(attributes) == 1
    # Whether we won or lost, this instance must now read what the TABLE says —
    # the loser's caller reports the standing outcome, and reporting it from a
    # stale in-memory copy would reintroduce the fiction in the log line.
    reload
    settled
  end

  # THE ONE WRITE A SETTLED ROW STILL ACCEPTS, and deliberately the narrowest one
  # that can exist: supply a MISSING merge sha on a row that already reads
  # EXECUTED. It never changes state, never replaces a sha already recorded, and
  # cannot touch a row in any other state — all three enforced in the WHERE clause
  # rather than in Ruby, for the same reason `settle!` is.
  #
  # It exists for a real interleave, not a hypothetical one. Two jobs run one
  # armed merge: the job that MERGES holds the sha GitHub returned, while the job
  # that merely READS the PR can legitimately see `merged: true` with
  # `merge_commit_sha` still absent — and the reader has the shorter path, so it
  # can reach the settle first. Winner-takes-all alone would then record a
  # truthful EXECUTED naming no sha, and the merge commit — the single most useful
  # fact on the row — would be lost to a scheduling accident.
  #
  # Returns true when this call supplied the sha.
  def record_merge_sha!(merge_sha, now: Time.current)
    sha = merge_sha.to_s.strip.presence
    return false if sha.blank?

    recorded = self.class.where(id: id, state: EXECUTED, merge_sha: nil)
                   .update_all(merge_sha: sha, updated_at: now) == 1
    reload
    recorded
  end

  def record_attempt!(now: Time.current)
    update!(attempts: attempts.to_i + 1, last_attempted_at: now)
  end

  private

  # The structural floor under ACTION_BASE_BRANCHES: every writer lands here, so a
  # console `create!`, a future second caller, or a raw update cannot record a
  # merge order pointing somewhere this action type may not go.
  def base_branch_matches_action
    return if base_branch_authorised?

    errors.add(:base_branch,
               "must be #{required_base_branch} for #{action} " \
               "(got #{base_branch.inspect}) — an armed merge may only target #{required_base_branch}")
  end
end
