# frozen_string_literal: true

require "test_helper"

# [unit] Task::Resubmission — "is this `building` task a fresh build, or a
# resubmission carrying a reviewer's send-back?"
#
# A `--kind rework` block leaves the task on `building` (Task#block!), so a bounced
# task and a never-reviewed one are the same shape on the board. These cases pin the
# distinction, and — deliberately — they drive REAL Activity and GithubWorkflowRun
# rows rather than a stubbed head oracle. The whole defect being fixed is a reader
# trusting a field that answers a different question than the one asked; a mock that
# answers the question we meant would reproduce that mistake in the test.
class TaskResubmissionTest < ActiveSupport::TestCase
  setup do
    GithubWorkflowRun.delete_all
    Activity.delete_all
    @bounce_at = Time.utc(2026, 9, 2, 14, 3, 57)
  end

  test "[unit] a task with no send-backs is a FRESH build" do
    task = building("fresh build task")
    seed_ci(task, sha: "aaaa1111", started_at: @bounce_at - 1.hour)

    state = task.resubmission

    assert_equal Task::Resubmission::FRESH, state.state
    assert_not state.resubmission?, "no qa_feedback row means nothing to warn about"
    assert_not state.surfaced?
    assert_equal 0, state.bounce_count
    assert_not state.breaker_tripped?
  end

  test "[unit] a bounce whose head has NOT moved reads UNADDRESSED" do
    # Instance 1+2's shape: the reviewer bounced 029a945b, and 029a945b is still the
    # head. Reviewing this task re-reads the tree that was already sent back.
    task = building("unmoved head task")
    seed_ci(task, sha: "029a945b", started_at: @bounce_at - 10.minutes)
    bounce!(task, at: @bounce_at)

    state = task.resubmission

    assert_equal Task::Resubmission::UNADDRESSED, state.state
    assert state.unaddressed?
    assert state.surfaced?, "a building task carrying an unaddressed send-back must be surfaced"
    assert_equal :red, state.scheme
    assert_includes state.label, "FEEDBACK NOT ADDRESSED"
    assert_equal "029a945b", state.head_at_bounce
    assert_equal "029a945b", state.head_now
  end

  test "[unit] a bounce whose head MOVED after it reads ADDRESSED" do
    task = building("moved head task")
    seed_ci(task, sha: "029a945b", started_at: @bounce_at - 10.minutes)
    bounce!(task, at: @bounce_at)
    seed_ci(task, sha: "bbbb2222", started_at: @bounce_at + 20.minutes)

    state = task.resubmission

    assert_equal Task::Resubmission::ADDRESSED, state.state
    assert_not state.unaddressed?
    assert_equal :amber, state.scheme
    assert_equal "029a945b", state.head_at_bounce
    assert_equal "bbbb2222", state.head_now
  end

  # ── THE LOAD-BEARING CASE ────────────────────────────────────────────────────
  #
  # Measured instance 2. The builder (or anyone) filed a `--resolves-feedback`
  # handoff, so Task#unresolved_feedback? answers FALSE and blocked_at/block_kind are
  # null — every prose field says "clear" — while the head never moved. A reader who
  # trusts the prose promotes the task and briefs a reviewer to read the blocked
  # tree, and the correct verdict is send-back 2 of 2, which escalates to the
  # operator over a resubmission that never happened.
  #
  # The claim must NOT override the tree.
  test "[unit] a resolves_feedback handoff does NOT clear an unmoved head" do
    task = building("hollow resolution task")
    seed_ci(task, sha: "029a945b", started_at: @bounce_at - 10.minutes)
    bounce!(task, at: @bounce_at)
    resolve!(task, at: @bounce_at + 5.minutes)

    assert_not task.unresolved_feedback?, "premise: the prose fields all read CLEAR here"
    assert_nil task.blocked_at, "premise: a rework block leaves blocked_at null by design"

    state = task.resubmission

    assert_equal Task::Resubmission::UNADDRESSED, state.state,
                 "the head is the honest signal; a resolution CLAIM must not overwrite it"
    assert state.breaker_tripped?, "the breaker is still armed — the next send-back escalates"
  end

  # ── FAIL-SAFE: UNKNOWN IS NEVER 'ADDRESSED' ──────────────────────────────────
  test "[unit] a bounce with NO ingested CI reads UNKNOWN, never addressed" do
    task = building("no ci task")
    bounce!(task, at: @bounce_at)

    state = task.resubmission

    assert_equal Task::Resubmission::UNKNOWN, state.state
    assert_not_equal Task::Resubmission::ADDRESSED, state.state
    assert state.surfaced?, "an unknown head still warrants a warning, not silence"
    assert_equal :amber, state.scheme
    assert_includes state.label, "HEAD UNKNOWN"
  end

  test "[unit] a head ingested only AFTER the bounce reads UNKNOWN, not addressed" do
    # Nothing resolves the tree the reviewer actually read, so "did it move?" is
    # unanswerable. Answering ADDRESSED here would clear a task on no evidence.
    task = building("post bounce ci only task")
    bounce!(task, at: @bounce_at)
    seed_ci(task, sha: "cccc3333", started_at: @bounce_at + 20.minutes)

    assert_equal Task::Resubmission::UNKNOWN, task.resubmission.state
  end

  # A task with no PR branch has no tree to ask about, which is a DIFFERENT fact from
  # "we looked and found no run". Saying HEAD UNKNOWN about it would read as broken
  # instrumentation rather than as the plain absence of a PR.
  test "[unit] a bounced task with NO PR branch says so, not HEAD UNKNOWN" do
    task = Task.create!(title: "no branch bounced task", stage: "submitted")
    bounce!(task, at: @bounce_at)

    state = task.resubmission

    assert_equal Task::Resubmission::UNKNOWN, state.state
    assert_not state.head_tracked?
    assert_not_includes state.label, "HEAD UNKNOWN"
    assert_includes state.label, "1 SEND-BACK"
    assert_includes state.title, "records no PR branch"
    assert state.breaker_tripped?
  end

  # ── WHICH ROWS COUNT — mirrors BounceLedger::COUNTABLE_KINDS ─────────────────
  test "[unit] environment and dependency blocks are NOT send-backs" do
    task = building("env blocked task")
    seed_ci(task, sha: "029a945b", started_at: @bounce_at - 10.minutes)
    bounce!(task, at: @bounce_at, kind: "environment")
    bounce!(task, at: @bounce_at + 1.minute, kind: "dependency")

    state = task.resubmission

    assert_equal Task::Resubmission::FRESH, state.state,
                 "an env blocker is a blocked desk and a dependency block is the ESCALATION; " \
                 "counting either would trip the breaker on its own output"
    assert_equal 0, state.bounce_count
  end

  test "[unit] an unclassified qa_feedback row COUNTS as a send-back" do
    # Rows written before kinds were stamped, and any `bin/task note --qa-feedback`.
    # In a safety read the safe reading of an unclassifiable row is that it might be
    # a bounce — missing a real one is the failure this whole family is about.
    task = building("legacy row task")
    seed_ci(task, sha: "029a945b", started_at: @bounce_at - 10.minutes)
    bounce!(task, at: @bounce_at, kind: nil)

    state = task.resubmission

    assert_equal Task::Resubmission::UNADDRESSED, state.state
    assert_equal 1, state.bounce_count
  end

  test "[unit] the LATEST send-back is the comparison point, and all of them are counted" do
    task = building("twice bounced task")
    seed_ci(task, sha: "aaaa1111", started_at: @bounce_at - 2.hours)
    bounce!(task, at: @bounce_at - 1.hour)
    seed_ci(task, sha: "bbbb2222", started_at: @bounce_at - 30.minutes)
    bounce!(task, at: @bounce_at)

    state = task.resubmission

    assert_equal 2, state.bounce_count
    assert_equal "bbbb2222", state.head_at_bounce, "compares against the LATEST bounce"
    assert_equal Task::Resubmission::UNADDRESSED, state.state
    assert_includes state.send_back_phrase, "2 send-backs"
  end

  # ── SCOPE: only while the work is still in the build/review lane ─────────────
  test "[unit] a shipped task's ledger is history, not a warning" do
    task = building("shipped later task")
    seed_ci(task, sha: "029a945b", started_at: @bounce_at - 10.minutes)
    bounce!(task, at: @bounce_at)
    task.update!(stage: "shipped")

    state = Task::Resubmission.for(task)

    assert state.resubmission?, "the ledger still records the send-back"
    assert_not state.surfaced?, "but a shipped task must not carry a resubmission warning"
  end

  test "[unit] a resubmission is surfaced in submitted too, not only building" do
    task = building("resubmitted and promoted task")
    seed_ci(task, sha: "029a945b", started_at: @bounce_at - 10.minutes)
    bounce!(task, at: @bounce_at)
    task.update!(stage: "submitted")

    assert Task::Resubmission.for(task).surfaced?,
           "instance 2 promoted the task to submitted; the warning must survive the move"
  end

  # ── THE VERDICT MUST NOT GO STALE ON AN INSTANCE ─────────────────────────────
  #
  # Task broadcasts its card on commit, and the broadcaster's card_locals read
  # #resubmission — so the verdict is computed on the LIVE instance at create/update
  # time, BEFORE the qa_feedback row that makes the task a resubmission exists. With a
  # `||=` on Task#resubmission that froze :fresh onto the instance and every later
  # read served it, the card render included. Measured while building this: the model
  # answered :unaddressed and the instance answered :fresh one line apart.
  test "[unit] a task instance re-reads the verdict after a send-back lands" do
    task = building("stale memo guard task")
    seed_ci(task, sha: "029a945b", started_at: @bounce_at - 10.minutes)

    assert_equal Task::Resubmission::FRESH, task.resubmission.state, "premise: nothing bounced yet"

    bounce!(task, at: @bounce_at)

    assert_equal Task::Resubmission::UNADDRESSED, task.resubmission.state,
                 "the SAME instance must see the send-back; a cached verdict is the very " \
                 "kind of stale field this whole feature exists to stop a reader trusting"
  end

  # ── THE VERDICT MUST NOT DEPEND ON THE STAGE ─────────────────────────────────
  #
  # Task#review_in_progress? is false unless the task is `submitted`, so a task
  # bounced back to `building` under a live review lease reports "no review in
  # progress" while a reviewer is demonstrably holding it (found on
  # /tasks/refusal-misnames-claim-holder). That is a signal that is right for
  # `submitted` and silently WRONG for exactly the tasks this class exists for — a
  # bounced task sits at `building`, which is the whole defect.
  #
  # This verdict must never acquire that shape. It is computed from the qa_feedback
  # ledger and the ingested CI rows, both of which are stage-free, and the ONLY stage
  # read in the class is #surfaced? — deliberate, explicit, and inclusive of
  # `building`. This pins that: identical ledger + identical tree ⇒ identical verdict,
  # whatever stage the task is sitting in.
  test "[unit] the verdict is identical across stages for an identical ledger and tree" do
    verdicts = %w[building submitted reviewed shipped].to_h do |stage|
      task = building("stage free verdict #{stage}")
      seed_ci(task, sha: "029a945b", started_at: @bounce_at - 10.minutes)
      bounce!(task, at: @bounce_at)
      task.update!(stage: stage)
      state = Task::Resubmission.for(task.reload)
      [stage, [state.state, state.bounce_count, state.head_at_bounce, state.head_now]]
    end

    assert_equal 1, verdicts.values.uniq.size,
                 "the verdict must not vary by stage — it did: #{verdicts.inspect}"
    assert_equal Task::Resubmission::UNADDRESSED, verdicts["building"].first,
                 "and `building` is the stage this whole class exists for"
  end

  # ── BATCH READ ───────────────────────────────────────────────────────────────
  test "[integration] for_tasks answers every task in one pass, per task" do
    fresh = building("batch fresh task")
    unaddressed = building("batch unmoved task")
    addressed = building("batch moved task")

    seed_ci(fresh, sha: "ffff0000", started_at: @bounce_at - 1.hour)
    seed_ci(unaddressed, sha: "029a945b", started_at: @bounce_at - 10.minutes)
    bounce!(unaddressed, at: @bounce_at)
    seed_ci(addressed, sha: "1111aaaa", started_at: @bounce_at - 10.minutes)
    bounce!(addressed, at: @bounce_at)
    seed_ci(addressed, sha: "2222bbbb", started_at: @bounce_at + 20.minutes)

    states = Task::Resubmission.for_tasks([fresh, unaddressed, addressed])

    assert_equal Task::Resubmission::FRESH, states.fetch(fresh.slug).state
    assert_equal Task::Resubmission::UNADDRESSED, states.fetch(unaddressed.slug).state
    assert_equal Task::Resubmission::ADDRESSED, states.fetch(addressed.slug).state
  end

  test "[integration] a task with no bounces costs NO workflow-run query" do
    # The board renders many cards; the head lookup must run only for tasks that
    # actually bounced. A board with no send-backs pays one activities read.
    tasks = 3.times.map { |i| building("cheap board task #{i}") }

    queries = 0
    counter = ->(_name, _start, _finish, _id, payload) do
      queries += 1 if payload[:sql].to_s.include?("github_workflow_runs")
    end

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      Task::Resubmission.for_tasks(tasks)
    end

    assert_equal 0, queries, "no bounced task means the head oracle must never be asked"
  end

  private

  def building(title)
    Task.create!(
      title: title, stage: "building",
      metadata: { "devops" => {
        "branch" => "feat/#{title.parameterize}",
        "repositories" => ["mcritchie-studio"],
        "pr_url" => "https://github.com/McRitchie-Studio/mcritchie-studio/pull/513"
      } }
    )
  end

  def seed_ci(task, sha:, started_at:)
    GithubWorkflowRun.create!(
      repo: "McRitchie-Studio/mcritchie-studio",
      workflow_name: GithubWorkflowRun::CI_WORKFLOW,
      run_id: SecureRandom.random_number(10**12),
      status: "completed", conclusion: "success",
      head_branch: task.devops_field("branch"), head_sha: sha,
      run_started_at: started_at, created_at: started_at
    )
  end

  def bounce!(task, at:, kind: "rework")
    metadata = { "summary" => "Sibling both-copies claims survive" }
    metadata["kind"] = kind if kind
    Activity.create!(
      task_slug: task.slug, activity_type: "qa_feedback",
      description: "The sibling's both-copies claims survive the change.",
      metadata: metadata, created_at: at, updated_at: at
    )
  end

  def resolve!(task, at:)
    Activity.create!(
      task_slug: task.slug, activity_type: "handoff",
      description: "Addressed the finding and reshipped.",
      metadata: { "resolves_feedback" => true }, created_at: at, updated_at: at
    )
  end
end
