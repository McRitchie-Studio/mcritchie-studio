# frozen_string_literal: true

# DeskRecord — the desk ledger, on the board.
#
# WHAT IT REPLACES, AND WHY THE FILE COULD NOT WORK. `bin/agent-worktree` wrote its
# teardown row into `docs/agents/maintenance/delete-later.md`, resolved against HUB_DIR.
# Cleanups are run from the PRIMARY checkout, and the primary sits on `main` — a branch
# nobody may commit to. So the audit row was created in the one place it could never be
# saved from. Six stashes of "restore later" ledger content piled up between 2026-07-02
# and 2026-08-31 (98 rows); not one was ever restored, and a reclaim sweep stranded 25
# more DURING the conversation about the defect. Every earlier fix idea relocated the
# write and still needed a human to remember a follow-up; a row here is durable the
# moment it lands, which is the acceptance bar met outright.
#
# ONE ROW PER EPISODE, NOT PER PATH. Desk paths RECYCLE — `_ship` is torn down once per
# release cycle at the same path — so identity is (worktree_path, the teardown that
# resolved it), exactly as it was in the file. A row whose `resolved_on` carries a date
# is HISTORY and is immutable; a row with no date is the OPEN item the next teardown
# closes in place. That is `LedgerGuard.resolved_row?`'s rule (a dated Status cell),
# reused rather than restated — the markdown ledger and its archive drifted apart in the
# first place because only one of them had the definition.
#
# IMMUTABILITY IS ENFORCED HERE, NOT DETECTED LATER. `bin/ledger-guard` had to judge the
# committed TREE because the offending writer was a stale COPY of the script and no rule
# added to the writer could reach it. That problem does not exist in this medium: there
# is one writer, this class, and it refuses a destructive write at the source. The guard
# keeps covering the markdown rows it always covered — see bin/ledger-guard's own header
# for the split.
class DeskRecord < ApplicationRecord
  # `live` — the desk exists and no sweep has nominated it.
  # `candidate` — a sweep filed it for approval (the file's "pending approval").
  # `removed` — torn down (the file's "removed <date>"); carries resolved_on.
  STATUSES = %w[live candidate removed].freeze

  # Where the write came from, so a row filed by a batch sweep is legible as such next
  # to one an operator typed by hand.
  SOURCES = %w[snapshot cleanup remove reclaim import].freeze

  RESOLVED_STATUS = "removed"

  # Raised when a write would rewrite or destroy a resolved episode. It is a refusal,
  # not a validation failure: the caller asked for something that must never happen, and
  # a 422 body that reads like a typo would understate it.
  class ResolvedRecordImmutable < StandardError; end

  validates :worktree_path, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :resolution_agrees_with_status

  before_update :refuse_rewriting_history
  before_destroy :refuse_destroying_history

  scope :open_episodes, -> { where(resolved_on: nil) }
  scope :resolved, -> { where.not(resolved_on: nil) }
  scope :live, -> { where(status: "live") }
  scope :candidates, -> { where(status: "candidate") }
  scope :removed, -> { where(status: RESOLVED_STATUS) }
  scope :for_app, ->(slug) { where(app_slug: slug) }
  scope :newest_first, -> { order(Arel.sql("COALESCE(recorded_at, created_at) DESC"), id: :desc) }

  # THE COLUMNS A WRITE MAY SET. Everything else on this table is bookkeeping the model
  # owns (status, resolved_on, timestamps), and letting a poster set those is how a
  # caller talks its way past the immutability rule.
  WRITABLE = %i[
    label app_slug desk_slug task_slug task_url source actor
    safety reason rationale withheld_reason safe_delete_condition cleanup_candidate
    branch head commit_subject base_ref dirty merged ahead behind
    health local_url app_port redis_db database payload last_seen_at
  ].freeze

  # The OPEN episode for a desk path, or nil. `newest_first` so the most recent open row
  # wins if a ledger ever carried more than one — the same `rindex` tie-break the file's
  # `open_ledger_row_index` used, for the same reason.
  def self.open_for(worktree_path)
    open_episodes.where(worktree_path: worktree_path).newest_first.first
  end

  # EVERY write goes through here.
  #
  # `status:` is what the caller is asserting about the desk right now. A `removed`
  # write CLOSES the open episode (or opens one already closed, for a desk this board
  # never saw live); any other status updates the open episode in place, or opens one.
  # A resolved row is never the target: it is history, and a second teardown of a
  # recycled path appends BESIDE it.
  def self.file!(worktree_path:, status: "live", resolved_on: nil, **attrs)
    raise ArgumentError, "unknown status #{status.inspect}" unless STATUSES.include?(status.to_s)

    resolving = status.to_s == RESOLVED_STATUS
    # A removal with no date supplied is dated NOW rather than left open — an undated
    # `removed` row would read as an open item forever, which is precisely the state the
    # file's own "a teardown closes its own pending row" rule exists to prevent.
    stamp = resolving ? (resolved_on || Date.current) : nil

    record = open_for(worktree_path) || new(worktree_path: worktree_path)
    record.assign_attributes(attrs.slice(*WRITABLE))
    record.status = status.to_s
    record.resolved_on = stamp
    record.recorded_at = Time.current
    record.save!
    record
  end

  # Fold ONE registry snapshot into the table: every desk it lists is seen, and the
  # sweep's own capacity/summary numbers are recorded alongside as a DeskSnapshot.
  #
  # A desk already carrying an OPEN candidate row is NOT downgraded back to `live` by a
  # later snapshot — the nomination is a decision, and a sweep that re-reads the desk a
  # minute later must not silently un-file it. Its facts still refresh.
  def self.sync!(payload)
    snapshot = DeskSnapshot.record!(payload)
    desks = Array(payload["worktrees"])

    desks.each do |desk|
      path = desk["worktree"].to_s
      next if path.empty?

      open = open_for(path)
      # `candidate` survives a resync; anything else (including a brand-new desk) is live.
      status = open&.status == "candidate" ? "candidate" : "live"
      file!(**registry_attributes(desk),
            status: status,
            source: "snapshot",
            last_seen_at: snapshot.generated_at)
    end

    snapshot
  end

  # The registry record (bin/agent-worktree's stack_record_snapshot) mapped onto columns.
  # ONE mapping, shared by the sync and the single-desk post, so the panel can never show
  # two different accounts of the same desk depending on which write got there first.
  def self.registry_attributes(desk)
    {
      worktree_path: desk["worktree"].to_s,
      label: desk["label"],
      app_slug: desk["app"],
      desk_slug: desk["task"],
      task_slug: desk["task_record_slug"],
      task_url: desk["task_url"],
      branch: desk["branch"],
      head: desk["head"],
      commit_subject: desk["commit_subject"],
      base_ref: desk["base_ref"],
      dirty: !!desk["dirty"],
      merged: !!desk["merged_to_origin_main"],
      ahead: desk["ahead_origin_main"].to_s,
      behind: desk["behind_origin_main"].to_s,
      health: desk["health"],
      local_url: desk["local_url"],
      app_port: desk["app_port"],
      redis_db: desk["redis_db"],
      database: desk["database"],
      cleanup_candidate: !!desk["cleanup_candidate"],
      withheld_reason: desk["withheld_reason"],
      rationale: desk["cleanup_rationale"],
      payload: desk
    }
  end

  # Open episodes the newest snapshot did not see — a desk that left without a teardown
  # record. This is the ONE question the markdown ledger could never answer, and it is
  # the detector for the defect class itself: something removed a desk outside the
  # audited path. It never guesses that they are gone; it reports that nothing has
  # confirmed them since.
  def self.vanished(as_of: nil)
    cutoff = as_of || DeskSnapshot.latest&.generated_at
    return none unless cutoff

    open_episodes.where(last_seen_at: ...cutoff).or(open_episodes.where(last_seen_at: nil))
  end

  def resolved? = resolved_on.present?

  # The Status cell the markdown ledger showed — kept so a reader moving between the
  # archive and this panel is reading one vocabulary.
  def status_label
    resolved? ? "removed #{resolved_on.strftime('%Y-%m-%d')}" : (status == "candidate" ? "pending approval" : "live")
  end

  # The safety argument in one sentence: why this desk was safe to take, or why it was
  # held. Never both, and never blank prose standing in for a decision nobody made.
  #
  # DIRTINESS IS ITS OWN ANSWER, and it has to be said here. The registry deliberately
  # leaves `withheld_reason` nil on a dirty desk — that field answers "why is this not a
  # candidate", and dirtiness already excluded it before any guard channel was asked. So a
  # dirty desk arrives with no rationale and no hold, and falls through to a line that reads
  # like nobody looked. What is true, and what a reader needs, is that somebody's
  # uncommitted work is sitting there.
  def safety_account
    return rationale if rationale.present?
    return "withheld — #{withheld_reason}" if withheld_reason.present?
    return "uncommitted work at this desk" if dirty?

    "no automatic clearance recorded"
  end

  private

  def resolution_agrees_with_status
    if status == RESOLVED_STATUS && resolved_on.blank?
      errors.add(:resolved_on, "is required for a removed desk")
    elsif status != RESOLVED_STATUS && resolved_on.present?
      errors.add(:status, "must be #{RESOLVED_STATUS} once resolved_on is set")
    end
  end

  # THE INVARIANT. `resolved_on_in_database` is the PERSISTED value, deliberately — the
  # close itself is an update that sets resolved_on for the first time, and reading the
  # in-memory attribute here would refuse the one write that is allowed.
  def refuse_rewriting_history
    return if attribute_in_database(:resolved_on).blank?

    raise ResolvedRecordImmutable,
          "desk record #{id} (#{worktree_path}) resolved #{attribute_in_database(:resolved_on)} is history. " \
          "Rows are appended beside a resolved episode, never over it — a recycled desk path is a new episode."
  end

  def refuse_destroying_history
    return if resolved_on.blank?

    raise ResolvedRecordImmutable,
          "desk record #{id} (#{worktree_path}) resolved #{resolved_on} is history and cannot be destroyed."
  end
end
