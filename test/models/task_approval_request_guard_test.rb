require "test_helper"

# [unit] The approval-request guard: a WAITING request that cannot be honoured is
# REFUSED at the fold, never accepted-and-settled in silence.
#
# THE DEFECT THIS CLOSES, reproduced 2026-09-07 across the full matrix. Same slug,
# same stage `submitted`, minutes apart:
#
#   bin/task update <slug> --approval waiting   -> exit 0, read-back "none"      DROPPED
#   bin/task update <slug> --approval approved  -> exit 0, read-back "approved"  LANDED
#
# The discriminator is neither the stage alone (the first filing's theory) nor the
# TRANSITION (none->waiting vs none->approved). It is the CONJUNCTION of stage and
# VALUE: #settle_operator_approval_past_submit rewrites ONLY "waiting", and only
# outside APPROVAL_REQUEST_STAGES. Proven by the prior-value control below — the
# settle fires from prior "approved", "changes_requested", "none" and nil alike, so
# the incoming transition is irrelevant.
#
# THE SETTLE IS CORRECT AND STAYS. It holds a real invariant (a waiting badge may
# exist only in a stage that can act on it) and it closes three documented leaks —
# see #settle_operator_approval_past_submit and the "later wholesale devops echo"
# tests in task_test.rb, which must keep self-healing SILENTLY. What was wrong is
# narrower: a caller that explicitly ASKS for "waiting" where it cannot be honoured
# got HTTP 200 / exit 0 for a write that reached nothing.
#
# WHY THAT IS WORSE THAN A TIDINESS BUG: approval_status "waiting" is the OPERATOR
# gate. Waiting tasks float to the top of their stage and pulse on the board, which
# is how Mr. McRitchie finds work needing his eyes. A dropped request means the
# agent believes it asked, the board never pulses, and the request reaches nobody —
# a human gate that reports success and does nothing. An agent cannot detect it
# without specifically re-reading approval_status, which the standard read-back
# guard does not do.
#
# So the guard refuses at the ONE fold both write paths share
# (Task.merge_devops_into_metadata), matching the house precedent already in
# normalize_devops_metadata: "a write that reaches nothing must be loud."
class TaskApprovalRequestGuardTest < ActiveSupport::TestCase
  SETTLE_STAGES = (Task::STAGES - Task::APPROVAL_REQUEST_STAGES).freeze

  def fold(stage:, **devops)
    Task.merge_devops_into_metadata({ "devops" => { "kind" => "bug" } }, devops.stringify_keys, stage)
  end

  # --- the ALLOW half of the matrix: where a request IS actionable ---

  test "[unit] a waiting request folds cleanly in every stage that can act on it" do
    assert_equal %w[designed building], Task::APPROVAL_REQUEST_STAGES,
                 "the allow-list moved; this matrix must move with it"

    Task::APPROVAL_REQUEST_STAGES.each do |stage|
      merged = fold(stage: stage, approval_status: "waiting")
      assert_equal "waiting", merged.dig("devops", "approval_status"),
                   "#{stage}: a request the operator can still act on must land"
    end
  end

  # --- the REFUSE half: the rows the coordinator measured as DROPPED ---

  test "[unit] a waiting request is refused loudly in every stage that would settle it" do
    SETTLE_STAGES.each do |stage|
      error = assert_raises(ArgumentError, "#{stage}: a dropped request must not report success") do
        fold(stage: stage, approval_status: "waiting")
      end

      # The message must carry BOTH halves of the discriminator, because either
      # alone misdirects the reader: the stage alone reads as a blanket metadata
      # lock (it is not — see the value matrix below), and the value alone reads as
      # "waiting is never writable" (it is, in designed and building).
      assert_includes error.message, stage, "#{stage}: the refusal must name the stage"
      assert_includes error.message, "waiting", "#{stage}: the refusal must name the value"
    end
  end

  test "[unit] the refusal points at the two ways forward" do
    error = assert_raises(ArgumentError) { fold(stage: "submitted", approval_status: "waiting") }

    assert_includes error.message, "designed", "name a stage where the request WOULD land"
    assert_includes error.message, "building", "name a stage where the request WOULD land"
    assert_includes error.message, "approved",
                    "an operator decision already given is still recordable — say so"
  end

  # --- the VALUE discriminator: prove we did NOT turn a value rule into a stage lock ---

  test "[unit] every settled approval value still folds in every stage" do
    (Task::STAGES - ["archived"]).each do |stage|
      %w[approved changes_requested none].each do |value|
        merged = fold(stage: stage, approval_status: value)
        assert_equal value, merged.dig("devops", "approval_status"),
                     "#{stage}/#{value}: only WAITING is unactionable past the seam"
      end
    end
  end

  test "[unit] an approved grant still lands at submitted" do
    # The coordinator's SECOND row, kept green: this is the half that already
    # worked, and a fix that broke it would be a worse bug than the one it closed.
    merged = fold(stage: "submitted", approval_status: "approved")

    assert_equal "approved", merged.dig("devops", "approval_status")
  end

  # --- the control the coordinator already held: this is not a metadata lock ---

  test "[unit] devops writes that never mention approval fold at every stage" do
    Task::STAGES.each do |stage|
      merged = fold(stage: stage, local_url: "http://localhost:3011/tasks")
      assert_equal "http://localhost:3011/tasks", merged.dig("devops", "local_url"),
                   "#{stage}: the guard must read the POSTED key, never lock the blob"
      assert_equal "bug", merged.dig("devops", "kind"), "#{stage}: unposted keys ride through"
    end
  end

  test "[unit] a refused request writes nothing at all, not half the call" do
    # bin/task update takes --approval and --local-url in ONE call. Failing CLOSED
    # means the whole write is refused, so the caller retries the whole thing —
    # rather than landing local_url and dropping the request, which is the split
    # outcome that made the original defect so hard to see.
    task = Task.create!(title: "Approval Guard Atomic Write", stage: "submitted",
                        metadata: { "devops" => { "kind" => "bug" } })

    assert_raises(ArgumentError) do
      Task.merge_devops_into_metadata(
        task.metadata,
        { "approval_status" => "waiting", "local_url" => "http://localhost:3011/x" },
        task.stage
      )
    end

    assert_nil task.reload.devops["local_url"], "a refused fold must leave the record untouched"
  end

  # --- the calling convention the guard must not break ---

  test "[unit] the fold still binds a brace-less trailing hash to raw_devops" do
    # THE TRAP, paid for on CI shard 4 on 2026-09-07. Callers write
    # `merge_devops_into_metadata(stored, "branch" => "feat/x")` with no braces. Give
    # this method ANY keyword and Ruby 3 binds that bare hash to the KEYWORDS instead
    # of to raw_devops — the call dies with "wrong number of arguments (given 1,
    # expected 2)" and every such call site breaks at once. `stage` is therefore a
    # trailing POSITIONAL. bin/task's `api` helper carries the same note, and it was
    # also a `stage` that blew it up there.
    merged = Task.merge_devops_into_metadata({ "devops" => { "kind" => "bug" } }, "branch" => "feat/x")

    assert_equal "feat/x", merged.dig("devops", "branch"),
                 "a bare trailing hash must still land as raw_devops, not as keywords"
    assert_equal "bug", merged.dig("devops", "kind")
  end

  test "[unit] the stage argument is positional and still guards" do
    assert_raises(ArgumentError) do
      Task.merge_devops_into_metadata({}, { "approval_status" => "waiting" }, "submitted")
    end
  end

  # --- the DROP RECEIPT: the transition clear must stop being silent ---
  #
  # The sequence the coordinator measured on 2026-09-07, reproduced here in full,
  # because it is the one that bites on the NORMAL path: set the request while
  # building, read it back, ship. Steps 1-3 are unchanged behaviour; what is new is
  # that step 3 now leaves a receipt instead of nothing.

  test "[unit] shipping a task drops its pending request and says so on the record" do
    task = Task.create!(title: "Approval Drop Receipt Row", stage: "building",
                        metadata: { "devops" => { "kind" => "bug" } })

    md = task.metadata.deep_dup
    (md["devops"] ||= {})["approval_status"] = "waiting"
    (md["devops"] ||= {})["local_url"] = "http://localhost:3011/demo"
    task.update!(metadata: md)
    assert_equal "waiting", task.reload.approval_status, "step 2: the request lands at building"
    assert_nil task.devops["approval_request_dropped_at"], "nothing dropped yet"

    task.submit! # step 3: what bin/ship does

    assert_equal "none", task.reload.approval_status, "the handoff still settles the request"
    assert task.devops["approval_request_dropped_at"].present?,
           "but the drop must now be AUDITABLE — this is the silence the operator loop paid for"
    assert_equal "http://localhost:3011/demo", task.devops["local_url"],
                 "local_url still survives the move, which is what made the drop look like success"
  end

  test "[unit] a move that drops nothing leaves no receipt" do
    # The receipt must mean something. A task with no pending request that crosses
    # the same seam must not be stamped, or the warning it drives cries wolf.
    task = Task.create!(title: "Approval No Drop Row", stage: "building",
                        metadata: { "devops" => { "kind" => "bug" } })

    task.submit!

    assert_nil task.reload.devops["approval_request_dropped_at"]
  end

  test "[unit] an approved grant crossing the seam is not a drop" do
    task = Task.create!(title: "Approval Grant Crosses Seam", stage: "building",
                        metadata: { "devops" => { "approval_status" => "approved" } })

    task.submit!

    task.reload
    assert_equal "approved", task.approval_status, "a real grant survives the handoff"
    assert_nil task.devops["approval_request_dropped_at"], "and nothing was discarded"
  end

  # --- the settle itself is UNCHANGED: the three leaks stay closed ---

  test "[unit] a direct model save past the seam still self-heals silently" do
    # LEAK 1 GUARD. A stale wholesale devops hash echoed onto an already-settled
    # task must keep resolving to "none" WITHOUT raising — that path is not a
    # caller asking for approval, it is a stale read, and turning it into a hard
    # failure would re-open the incident the settle was written for.
    task = Task.create!(title: "Approval Guard Settle Intact", stage: "building",
                        metadata: { "devops" => { "approval_status" => "waiting" } })
    task.submit!
    assert_equal "none", task.reload.approval_status

    stale = task.metadata.deep_dup
    stale["devops"]["approval_status"] = "waiting"
    assert_nothing_raised { task.update!(metadata: stale) }

    assert_equal "none", task.reload.approval_status,
                 "the model settle stays the invariant holder; the guard only fronts the fold"
  end

  test "[unit] carrying a live request through the submit move still settles" do
    # The legitimate internal settle: the request EXISTED and the stage moved under
    # it. Nobody asked for anything on this save, so nothing may raise.
    task = Task.create!(title: "Approval Guard Carry Through", stage: "building",
                        metadata: { "devops" => { "approval_status" => "waiting" } })

    assert_nothing_raised { task.submit! }
    assert_equal "none", task.reload.approval_status
  end
  # --- the copies of this rule that live OUTSIDE the model ---
  #
  # [unit] APPROVAL_REQUEST_STAGES is the settle's whole trigger, and two places
  # outside app/models/task.rb now decide behaviour from their own copy of it:
  # bin/task, whose move warning refuses to announce a drop on a destination that
  # can HOLD a request, and the CLI test's stub board, which models the settle so a
  # drop can be told apart from a stamp already on the record. A copy that drifts
  # does not fail loudly — it silently certifies a rule the board no longer holds.
  #
  # Pinned HERE rather than beside either copy because test/lib/task_cli_test.rb is
  # deliberately standalone (no Rails, no network) and cannot see Task at all: the
  # first cut of this pin sat in that file behind `defined?(::Task)` and SKIPPED in
  # both lanes, including under `bin/rails test`, which does not boot the app for a
  # file that never requires test_helper. A pin that cannot read its subject pins
  # nothing, so each assertion below first proves it actually FOUND the literal.
  def test_bin_task_pins_the_real_approval_request_stages
    assert_equal Task::APPROVAL_REQUEST_STAGES.map(&:to_s).sort,
                 stage_literal_in("bin/task", /^APPROVAL_REQUEST_STAGES = %w\[([^\]]*)\]/)
  end

  def test_the_cli_stub_board_models_the_real_approval_request_stages
    assert_equal Task::APPROVAL_REQUEST_STAGES.map(&:to_s).sort,
                 stage_literal_in("test/lib/task_cli_test.rb", /^\s*SETTLE_EXEMPT_STAGES = %w\[([^\]]*)\]/)
  end

  private

  # Reads a %w[] stage literal out of a source file. A miss is a FAILURE naming the
  # file and the pattern, never an empty array that would compare equal to nothing
  # and pass — a renamed or reformatted constant must turn this red, not silent.
  def stage_literal_in(relative_path, pattern)
    source = Rails.root.join(relative_path).read
    match = source.match(pattern)
    refute_nil match,
               "#{relative_path} no longer declares its stage list as #{pattern.source} — " \
               "the copy moved or was reformatted, so this pin stopped reading it"
    match[1].split.sort
  end
end
