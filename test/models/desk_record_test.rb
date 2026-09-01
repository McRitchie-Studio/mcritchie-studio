require "test_helper"

# The desk ledger's move-never-delete invariant, in its new medium.
#
# These are the SAME properties test/lib/agent_worktree_test.rb used to assert against the
# markdown file — a recycled desk path gets a row PER TEARDOWN, a teardown closes its own
# pending row in place, only an undated row is open for overwrite — ported to the table that
# replaced it. They are the reason a resolved episode is safe here: the file needed
# bin/ledger-guard to judge the committed tree because the offending writer was a STALE COPY
# of a script no rule could reach, and this medium has exactly one writer.
class DeskRecordTest < ActiveSupport::TestCase
  SHIP = "/Users/alex/projects/mcritchie-studio/.worktrees/_ship"

  def file(path: SHIP, status: "live", **attrs)
    DeskRecord.file!(worktree_path: path, status: status, **attrs)
  end

  # ---- [unit] episode identity: one row per TEARDOWN, not per PATH -----------------

  # THE PROPERTY. Tear the SAME path down twice; both records must survive, each carrying
  # its own HEAD and its own date. A test that removes one path once passes blind against
  # this defect, which is why this one removes twice and counts.
  test "[unit] two teardowns of one recycled path keep both episodes" do
    file(status: "removed", resolved_on: Date.new(2026, 8, 18), head: "c46790dc")
    file(status: "removed", resolved_on: Date.new(2026, 8, 19), head: "9f13ab27")

    rows = DeskRecord.where(worktree_path: SHIP).order(:id)

    assert_equal 2, rows.size,
                 "a recycled desk path gets an episode PER TEARDOWN; keying the update on the " \
                 "path alone is what lost the 08-18 `_ship` rows for good"
    assert_equal [Date.new(2026, 8, 18), Date.new(2026, 8, 19)], rows.map(&:resolved_on)
    assert_equal %w[c46790dc 9f13ab27], rows.map(&:head)
  end

  # The other direction, and the reason "always append" is NOT the fix. `cleanup --write`
  # files an OPEN candidate; the teardown that follows RESOLVES that same episode and must
  # close it in place. Appending there would leave a pending record for a desk that no
  # longer exists — a ledger that reads as unfinished work forever.
  test "[unit] a teardown closes its own pending episode in place" do
    candidate = file(status: "candidate", head: "c46790dc")
    removed = file(status: "removed", resolved_on: Date.new(2026, 8, 18), head: "c46790dc")

    assert_equal candidate.id, removed.id, "the pending record is the SAME episode — closed, not duplicated"
    assert_equal 1, DeskRecord.where(worktree_path: SHIP).count
    assert_equal 0, DeskRecord.where(worktree_path: SHIP, status: "candidate").count,
                   "a resolved desk must not also stand as an open candidate"
  end

  # The rule itself, in isolation: a DATED record is history and is never the target of a
  # write; an undated one is the open item the next teardown closes. Same definition
  # LedgerGuard.resolved_row? reads off the markdown Status cell, which is the point — the
  # two ledgers drifted apart in the first place because only one of them had it.
  test "[unit] only an unresolved episode is open for a later write" do
    resolved = file(status: "removed", resolved_on: Date.new(2026, 8, 18))

    assert_nil DeskRecord.open_for(SHIP), "a resolved episode is never reopened"

    pending = file(status: "candidate")

    assert_equal pending.id, DeskRecord.open_for(SHIP).id
    refute_equal resolved.id, pending.id

    sibling = file(path: "#{SHIP}-2", status: "candidate")

    assert_equal pending.id, DeskRecord.open_for(SHIP).id,
                 "a LONGER sibling path must not match, or one desk's teardown rewrites another's"
    assert_equal sibling.id, DeskRecord.open_for("#{SHIP}-2").id
  end

  # ---- [unit] resolved episodes are immutable -------------------------------------

  test "[unit] a resolved episode refuses an update" do
    record = file(status: "removed", resolved_on: Date.new(2026, 8, 18), reason: "torn down")

    error = assert_raises(DeskRecord::ResolvedRecordImmutable) { record.update!(reason: "rewritten") }
    assert_match(/history/, error.message)
    assert_equal "torn down", record.reload.reason
  end

  test "[unit] a resolved episode refuses destruction" do
    record = file(status: "removed", resolved_on: Date.new(2026, 8, 18))

    assert_raises(DeskRecord::ResolvedRecordImmutable) { record.destroy }
    assert DeskRecord.exists?(record.id)
  end

  # The one update that IS allowed: the close itself. The guard reads the PERSISTED
  # resolved_on, and reading the in-memory attribute instead would refuse this write —
  # the single most important write on the destroy path.
  test "[unit] closing an open episode is not refused" do
    open = file(status: "candidate")

    assert_nothing_raised { file(status: "removed", resolved_on: Date.new(2026, 8, 20)) }
    assert_equal Date.new(2026, 8, 20), open.reload.resolved_on
  end

  # ---- [unit] status and resolution can never disagree ----------------------------

  test "[unit] a removed record is always dated" do
    record = file(status: "removed")

    assert_equal Date.current, record.resolved_on,
                 "an undated `removed` row would read as an open item forever"
  end

  test "[unit] a live record may not carry a resolution date" do
    record = DeskRecord.new(worktree_path: SHIP, status: "live", resolved_on: Date.current)

    refute_predicate record, :valid?
    assert_includes record.errors[:status].join, "removed"
  end

  test "[unit] an unknown status is refused rather than coerced" do
    assert_raises(ArgumentError) { DeskRecord.file!(worktree_path: SHIP, status: "torn-down") }
  end

  # ---- [unit] the registry mapping ------------------------------------------------

  REGISTRY_DESK = {
    "label" => "mcritchie-studio/_ship",
    "app" => "mcritchie-studio",
    "task" => "_ship",
    "task_record_slug" => "ship-it",
    "task_url" => "https://mcritchie.studio/tasks/ship-it",
    "worktree" => SHIP,
    "branch" => "release",
    "head" => "be798149",
    "commit_subject" => "Ship the release",
    "dirty" => false,
    "base_ref" => "origin/accepted",
    "merged_to_origin_main" => true,
    "ahead_origin_main" => "0",
    "behind_origin_main" => "3",
    "health" => "down",
    "local_url" => "http://localhost:3024",
    "app_port" => 3024,
    "redis_db" => 24,
    "database" => "hub_ship",
    "cleanup_candidate" => true,
    "withheld_reason" => nil,
    "cleanup_rationale" => "merged into origin/accepted, tree clean"
  }.freeze

  test "[unit] the registry record maps onto columns without losing the raw payload" do
    record = DeskRecord.file!(**DeskRecord.registry_attributes(REGISTRY_DESK), status: "live")

    assert_equal SHIP, record.worktree_path
    assert_equal "mcritchie-studio", record.app_slug
    assert_equal "_ship", record.desk_slug
    assert_equal "ship-it", record.task_slug
    assert_equal "release", record.branch
    assert_equal 24, record.redis_db
    assert record.merged
    assert record.cleanup_candidate
    assert_equal "merged into origin/accepted, tree clean", record.rationale
    # The door left open for /tasks/harvest-stranded-ledger-stashes: nothing the snapshot
    # knew is dropped on the way in, INCLUDING the fields this table has no column for.
    assert_equal REGISTRY_DESK, record.payload
  end

  # ---- [unit] the sync ------------------------------------------------------------

  def registry(generated_at: "2026-08-31T21:39:33Z", desks: [REGISTRY_DESK])
    {
      "generated_at" => generated_at,
      "projects_dir" => "/Users/alex/projects",
      "hub_dir" => "/Users/alex/projects/mcritchie-studio",
      "capacity" => { "floor" => 20, "step" => 10, "current" => 55, "used" => 25, "free" => 30, "physical_max" => 64 },
      "summary" => { "worktrees" => desks.size, "dirty_worktrees" => 1, "withheld" => 57, "cleanup_candidates" => 0 },
      "redis_db_range" => { "min" => 9, "max" => 63 },
      "worktrees" => desks
    }
  end

  test "[unit] a sync records the run's capacity and sees every desk" do
    snapshot = DeskRecord.sync!(registry)

    assert_equal 1, snapshot.desk_count
    assert_equal 30, snapshot.free_slots
    assert_equal 55, snapshot.band_size
    assert_equal 57, snapshot.withheld_desks
    assert_equal 1, DeskRecord.open_episodes.count
    assert_equal snapshot.generated_at, DeskRecord.open_for(SHIP).last_seen_at
  end

  # A nomination is a DECISION. A snapshot that runs a minute later must refresh the desk's
  # facts without silently un-filing it — otherwise the sweep's own registry refresh
  # (run_snapshot fires at the end of every remove) would undo the candidate it just filed.
  test "[unit] a resync refreshes a candidate's facts without downgrading it" do
    DeskRecord.file!(worktree_path: SHIP, status: "candidate", head: "old")
    DeskRecord.sync!(registry)

    record = DeskRecord.open_for(SHIP)

    assert_equal "candidate", record.status, "a nomination is a decision, not a reading"
    assert_equal "be798149", record.head, "…and its facts still refresh"
  end

  test "[unit] a sync never rewrites a resolved episode" do
    DeskRecord.file!(worktree_path: SHIP, status: "removed", resolved_on: Date.new(2026, 8, 18), head: "gone")
    DeskRecord.sync!(registry)

    assert_equal 2, DeskRecord.where(worktree_path: SHIP).count,
                 "the desk is live again at a recycled path: a NEW episode beside the resolved one"
    assert_equal "gone", DeskRecord.resolved.find_by(worktree_path: SHIP).head
  end

  # ---- [unit] the defect detector -------------------------------------------------

  # An open episode the newest snapshot did not see is a desk that left outside
  # `bin/agent-worktree remove` — the exact loss this whole change exists to end. It is
  # never inferred away; it is reported.
  test "[unit] an open episode the latest snapshot did not see reads as vanished" do
    DeskRecord.sync!(registry)
    seen = DeskRecord.open_for(SHIP)

    assert_empty DeskRecord.vanished.to_a, "a desk in the newest snapshot is not vanished"

    DeskRecord.sync!(registry(generated_at: "2026-08-31T22:39:33Z", desks: []))

    assert_equal [seen.id], DeskRecord.vanished.map(&:id)
  end

  test "[unit] nothing is vanished before the first snapshot" do
    DeskRecord.file!(worktree_path: SHIP, status: "live")

    assert_empty DeskRecord.vanished.to_a,
                 "with no snapshot to compare against, the honest answer is not `gone`"
  end

  # ---- [unit] the reader's vocabulary ---------------------------------------------

  test "[unit] the status label reads as the markdown ledger's Status cell did" do
    assert_equal "live", file(status: "live").status_label
    assert_equal "pending approval", file(status: "candidate").status_label
    assert_equal "removed 2026-08-18",
                 file(status: "removed", resolved_on: Date.new(2026, 8, 18)).status_label
  end

  test "[unit] the safety account never leaves a blank cell standing for a decision" do
    assert_equal "cleared: merged", file(rationale: "cleared: merged").safety_account
    assert_equal "withheld — a builder is live-claiming it",
                 file(path: "#{SHIP}-2", withheld_reason: "a builder is live-claiming it").safety_account
    assert_equal "no automatic clearance recorded", file(path: "#{SHIP}-3").safety_account
    # A dirty desk carries NEITHER a rationale nor a hold — the registry leaves
    # withheld_reason nil because dirtiness excluded it before any guard was asked — so
    # without this branch the panel would say "nobody looked" about somebody's live work.
    assert_equal "uncommitted work at this desk",
                 file(path: "#{SHIP}-4", dirty: true).safety_account
  end
end
