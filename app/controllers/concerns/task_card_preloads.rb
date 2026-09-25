# The per-card preloads the board card partial (tasks/_task_card) reads, batched once
# per page so a column of cards costs one query instead of one per card. Shared by
# the two boards (TasksController#load_board) and the epic page (EpicsController#show),
# which render the same card and so owe it the same locals.
module TaskCardPreloads
  extend ActiveSupport::Concern

  private

  def load_board_task_conversation(tasks)
    task_slugs = tasks.map(&:slug)
    activities = Activity.where(task_slug: task_slugs, activity_type: Activity::TASK_CONVERSATION_TYPES)
    @task_activity_counts = activities.group(:task_slug).count
    @latest_task_activities = activities.recent.each_with_object({}) do |activity, memo|
      memo[activity.task_slug] ||= activity
    end
    @unresolved_feedback_activities = Task.unresolved_feedback_by_slug(task_slugs)
    # Which tasks ever carried a QA block — the "was blocked" half of the card's
    # tri-state tone (a cleared block wears amber, awaiting re-review). One indexed
    # query for the whole board, so a card never queries per-slug (mirrors
    # @unresolved_feedback_activities).
    @ever_blocked_slugs = Activity.where(task_slug: task_slugs, activity_type: "qa_feedback")
                                  .distinct.pluck(:task_slug).to_set
    # FRESH BUILD OR RESUBMISSION, per card. Batched for the same reason as the two
    # reads above, and it costs the board almost nothing: the head oracle is only
    # asked about tasks that ACTUALLY carry a send-back, so a board with none pays
    # one activities query and no more. See Task::Resubmission.
    @resubmissions = Task::Resubmission.for_tasks(tasks)
  end

  # CI meters and local-check indicators for every card about to render.
  def load_task_card_readers(tasks)
    # CI progress bars: one batched read for every open PR's GitHub CI (building
    # through assembled — a shipping builder's PR is live news while it waits on CI),
    # so a card never issues its own check-runs call. Degrades to an empty map (no
    # bars) on any error — the reader rescues its own reads to blank, and this outer
    # rescue guards the batch itself so a reader failure never 500s the whole board.
    @ci_progress_by_slug = begin
      Ci::ProgressReader.new.progress_by_slug(tasks)
    rescue StandardError => e
      ErrorLog.capture!(e)
      {}
    end
    # Local-check indicators: ONE batched read of the in-flight g1_cert attempts
    # across every card about to render, so a board full of building tasks issues
    # one GateRun query instead of one per card. Same blast-radius rule as the CI
    # batch above — a reader failure degrades to no indicators, never a 500.
    @local_check_by_slug = begin
      Cert::LocalCheckReader.new.for_tasks(tasks)
    rescue StandardError => e
      ErrorLog.capture!(e)
      {}
    end
  end
end
