class TasksController < ApplicationController
  # The `reorder` action, its `slugs` guard, the 100-gap restamp (delegated to
  # Task's Studio::Board::Rankable#reposition!), and the ErrorLog-logging + 422 net
  # all come from the shared board primitive concern. The board POSTs
  # `{ slugs: [...ids], zone: "<stage>" }`; the action reads only `slugs`.
  include Studio::Board::Reorderable
  board_reorderable model: Task, id_attr: :slug, param: :slugs

  skip_before_action :verify_authenticity_token, if: -> { request.format.json? }
  # `local_review` joins the public read actions deliberately — see the action.
  # It is the board's WAITING APPROVAL CTA, and gating it on a board session is
  # what broke one-click review: a logged-out click 302'd to /login, and
  # require_authentication keeps no return_to, so the click was thrown away.
  PUBLIC_ACTIONS = [:index, :show, :recent, :review_events, :review_events_hub,
                    :deployments, :stages, :sop, :local_review].freeze

  skip_before_action :require_authentication, only: PUBLIC_ACTIONS
  before_action :require_admin, except: PUBLIC_ACTIONS
  before_action :set_task, only: [:show, :review_events, :local_review, :edit, :update, :destroy, :comment, :block, :unblock]

  # /tasks — Workflow 1 (Build, feature agent): designed → building → submitted
  # (a block is a `building` attribute, not a lane).
  def index
    load_board
  end

  # /deployments — Workflow 2 (Deploy, DevOps): submitted → reviewed → assembled →
  # shipped, led by the current-release module.
  def deployments
    load_board
    @current_release = Release.current
    @last_release = Release.last_shipped
    @release_duration_dashboard = Release.deployment_stage_averages
  end

  # Row budget for /tasks/recent — enough to cover the active pipeline plus the
  # last few shipped cycles without turning the scan into a scroll marathon.
  RECENT_TASKS_LIMIT = 50

  # /tasks/recent — a flat recency list (updated_at desc), the scanning surface
  # for per-task testing-phase durations (Task::TestingPhases) + gate verdicts
  # (GateRun). Read-only and public like the board; archived tasks are terminal
  # noise here, so they're excluded (the board hides them behind a toggle too).
  def recent
    @tasks = Task.where.not(stage: "archived")
                 .order(updated_at: :desc, id: :desc)
                 .limit(RECENT_TASKS_LIMIT)
                 .to_a
    @gate_runs_by_task = GateRun.latest_by_key_for_subjects(
      subject_type: "task",
      subject_slugs: @tasks.map(&:slug)
    )
  end

  # /stages — the two-workflow stage guide (vertical swimlanes, side by side).
  def stages
  end

  # /stages/sop — the operator's DevOps SOP as an accountability-swimlane
  # infographic (one row per owner). Static guide; data lives in
  # ApplicationHelper#devops_sop_lanes. Public-read like /stages.
  def sop
  end

  def show
    load_task_conversation
    @unresolved_feedback_activity = @task.unresolved_feedback_activity
    @task_events = @task.task_events.chronological.to_a
    @agents = Agent.order(:position)
    @active_review_intent = @task.open_intent_for("reviewed")
    @testing_phases = Task::TestingPhases.cached_or_built(@task)
    @task_gate_runs = GateRun.latest_by_key(subject_type: "task", subject_slug: @task.slug)
  end

  def review_events
    @task_events = @task.task_events.chronological.to_a
    @review_events = @task.review_check_in_events
    load_review_process_context
  end

  # The board's WAITING APPROVAL CTA target: bounce the click to the LOCAL
  # stack's own dev-only mint endpoint, which signs the reviewer in there and
  # lands them on the page under review. One click, from a cold browser.
  #
  # PUBLIC, and no email travels with it. Both were once true the other way, and
  # both broke the one thing this button is for:
  #
  #   * It required an admin BOARD session. A logged-out click 302'd to /login,
  #     and require_authentication keeps no return_to — so the click was thrown
  #     away and signing in dropped you nowhere near the review. "One click"
  #     became "sign in, navigate back, click again".
  #   * It passed current_user.email. With no sign-in there is no current_user,
  #     and putting an address in this redirect would publish the operator's
  #     email on a public page for anyone to read.
  #
  # So the local stack answers "who is sitting at this desk?" itself
  # (Studio.local_review_email, else its first admin — studio-engine >= 0.33.0).
  # Opening this up grants nothing: every destination is loopback, so the only
  # server a stranger's click can reach is their OWN machine.
  #
  # It used to mint the magic link HERE and redirect to this app's /l/<token>.
  # That could never work from the production board: a magic link signs you into
  # the app that minted it, and return_to is sanitized to a same-origin PATH — so
  # the operator arrived signed into PRODUCTION at the local page's path. Only
  # the local server can create a local session, so only the local server can
  # mint. See LocalReviewLink (loopback-only) and studio-engine's
  # Studio::LocalReviewsController (the endpoint on the other end, >= 0.19).
  #
  # No write happens here anymore — nothing to wrap in rescue_and_log.
  def local_review
    local_url = @task.devops_url("local")
    return redirect_to(task_path(@task.slug), alert: "This task has no local demo URL yet.") if local_url.blank?

    target = LocalReviewLink.for(local_url: local_url)
    if target.blank?
      return redirect_to(task_path(@task.slug),
                         alert: "This task's local demo URL is not a local server — open it yourself: #{local_url}")
    end

    # allow_other_host: the whole point is to leave this host for localhost:<port>.
    # LocalReviewLink refuses anything that is not loopback, so the set of hosts
    # reachable here is exactly "a server on this machine".
    redirect_to target, allow_other_host: true
  end

  def review_events_hub
    load_review_process_context
  end

  def new
    followup_slug = params[:followup_from].to_s.strip.presence
    @followup_source = Task.find_by(slug: followup_slug) if followup_slug
    @task = @followup_source ? followup_task_from(@followup_source) : Task.new
    @agents = Agent.active.order(:position)
  end

  def create
    @task = Task.new(task_params)
    rescue_and_log(target: @task) do
      @task.save!
      redirect_to task_path(@task.slug), notice: "Task created."
    end
  rescue StandardError => e
    @agents = Agent.active.order(:position)
    render :new, status: :unprocessable_entity
  end

  def edit
    @agents = Agent.active.order(:position)
  end

  def update
    rescue_and_log(target: @task) do
      Current.task_event_source = "web"
      Current.task_event_actor = current_activity_agent_slug || current_user&.email
      @task.update!(task_params)
      respond_to do |format|
        format.html { redirect_to task_path(@task.slug), notice: "Task updated." }
        format.json { render json: @task }
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html do
        @agents = Agent.active.order(:position)
        render :edit, status: :unprocessable_entity
      end
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def destroy
    rescue_and_log(target: @task) do
      @task.destroy!
      respond_to do |format|
        format.html { redirect_to tasks_path, notice: "Task deleted." }
        format.json { head :no_content }
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to tasks_path, alert: e.message }
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  # Block is a `building` attribute (blocked_at + block_kind + blocked_by), not a
  # stage move — the show-page "Block" control. Server-enforced via Task#block!.
  def block
    rescue_and_log(target: @task) do
      Current.task_event_source = "web"
      blocker = current_activity_agent_slug
      Current.task_event_actor = blocker || current_user&.email
      @task.block!(by: blocker, kind: params[:kind].presence || "rework")
      redirect_to task_path(@task.slug), notice: "Task blocked."
    end
  rescue StandardError => e
    redirect_to task_path(@task.slug), alert: e.message
  end

  # Clear a live block, leaving the task on `building` — the show-page "Resume"
  # control (Task#unblock!).
  def unblock
    rescue_and_log(target: @task) do
      Current.task_event_source = "web"
      Current.task_event_actor = current_activity_agent_slug || current_user&.email
      @task.unblock!
      redirect_to task_path(@task.slug), notice: "Task unblocked."
    end
  rescue StandardError => e
    redirect_to task_path(@task.slug), alert: e.message
  end

  def comment
    @task_activity = @task.activities.build(task_activity_params)
    @task_activity.activity_type = permitted_task_activity_type(@task_activity.activity_type)
    @task_activity.agent_slug = current_activity_agent_slug if @task_activity.agent_slug.blank?
    @task_activity.metadata = task_activity_metadata(@task_activity.metadata)

    rescue_and_log(target: @task_activity, parent: @task) do
      @task_activity.save!
      respond_to do |format|
        format.html { redirect_to task_path(@task.slug), notice: "Task feedback added." }
        format.json { render json: @task_activity, status: :created }
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html do
        load_task_conversation
        flash.now[:alert] = e.message
        render :show, status: :unprocessable_entity
      end
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  private

  def set_task
    @task = Task.find_by(slug: params[:slug])
    return redirect_to tasks_path, alert: "Task not found" unless @task
  end

  # The same-origin PATH of the task's local page, pulled from its full local_url
  # (e.g. "http://localhost:3009/demo?x=1" -> "/demo?x=1"). Studio::Link keeps only
  # a same-origin path as return_to (an absolute URL sanitizes to nil), so the path
  # is extracted here; anything unparseable falls back to root.
  def load_task_conversation
    @task_activities = @task.activities.includes(:agent).conversation_order
    @task_activity ||= @task.activities.build(activity_type: "comment")
  end

  def followup_task_from(source)
    Task.new(
      title: "Followup Review Changes",
      description: followup_description(source),
      priority: source.priority,
      metadata: { "devops" => followup_devops_metadata(source) }
    )
  end

  def followup_devops_metadata(source)
    {
      "kind" => source.devops_kind.presence || "feature",
      "shape" => source.devops_shape.presence,
      "repositories" => source.devops_repositories,
      "risk_tags" => (source.devops_risk_tags + ["review-followup"]).uniq,
      "acceptance" => [
        "Followup captures post review changes safely",
        "Original review continues without interruption"
      ],
      "test_plan" => [
        "Run focused checks for followup scope"
      ]
    }.compact
  end

  def followup_description(source)
    lines = [
      "Follow-up to #{source.title} (#{source.slug}).",
      "",
      "The original task is already in review. Capture new changes here instead of pushing to the branch under review."
    ]
    lines << "PR: #{source.devops_url("pr")}" if source.devops_url("pr")
    lines.join("\n")
  end

  # Shared data loader for /tasks and /deployments — same task set, different
  # columns. Each view passes its own column list to the _board partial; archived
  # is a board-side toggle, so grouping the full task set here is intentional.
  def load_board
    # :gate_runs rides along with :task_events because the claim chip reads BOTH for
    # its progress fact (last durable artifact + is a gate in flight) — preloading
    # only the events would leave the chip issuing a fresh gate query per live card.
    tasks = Task.ordered.includes(:task_events, :gate_runs)
    agent_filter = params[:agent_slug].presence || params[:agent].presence
    tasks = tasks.where(agent_slug: agent_filter) if agent_filter
    stage_filter = params[:stage].presence
    tasks = tasks.where(stage: stage_filter) if Task::STAGES.include?(stage_filter)
    load_board_task_conversation(tasks)
    @tasks_by_stage = tasks.group_by(&:stage)
    # CI progress bars: one batched read for every submitted-onward PR's GitHub CI,
    # so a card never issues its own check-runs call. Degrades to an empty map (no
    # bars) on any error — the reader rescues its own reads to blank, and this outer
    # rescue guards the batch itself so a reader failure never 500s the whole board.
    @ci_progress_by_slug = begin
      Ci::ProgressReader.new.progress_by_slug(tasks)
    rescue StandardError => e
      ErrorLog.capture!(e)
      {}
    end
    @agents = Agent.order(:position)
  end

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
  end

  def load_review_process_context
    @agents = Agent.order(:position).to_a
    @review_process = ReviewProcessHub.new(agents: @agents)
    @review_pipeline_tasks = @review_process.pipeline_tasks
  end

  def task_activity_params
    params.require(:activity).permit(:activity_type, :description, metadata: {})
  end

  def permitted_task_activity_type(type)
    type = type.to_s
    Activity::TASK_CONVERSATION_TYPES.include?(type) ? type : "comment"
  end

  def current_activity_agent_slug
    prefix = current_user&.email.to_s.split("@").first.presence
    return prefix if prefix && Agent.exists?(slug: prefix)

    nil
  end

  def task_activity_metadata(raw_metadata)
    metadata = raw_metadata.presence || {}
    metadata.to_h.merge(
      "source" => "task_conversation",
      "user_id" => current_user&.id
    ).compact
  end

  def task_params
    permitted = params.require(:task).permit(
      :title,
      :description,
      :priority,
      :agent_slug,
      :stage,
      devops: [
        :kind,
        :shape,
        :worktree_slug,
        :branch,
        :pr_url,
        :local_url,
        :qa_url,
        :production_url,
        :release_slug,
        :release_train,
        :requires_release_conductor,
        :included_in_release,
        :approval_status,
        :approval_requested_at,
        :approval_requested_by,
        :post_deploy_cmd,
        :repositories,
        :risk_tags,
        :acceptance,
        :test_plan,
        :checks_run
      ]
    )
    attrs = permitted.except(:devops).to_h
    return attrs unless permitted[:devops]

    attrs[:metadata] = merged_metadata_with_devops(permitted[:devops])
    attrs
  end

  def merged_metadata_with_devops(raw_devops)
    base = (@task&.metadata || {}).deep_dup
    normalized = Task.normalize_devops_metadata(raw_devops)
    if normalized.any?
      base["devops"] = normalized
    else
      base.delete("devops")
    end
    base
  end
end
