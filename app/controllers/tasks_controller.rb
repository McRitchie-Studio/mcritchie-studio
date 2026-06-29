class TasksController < ApplicationController
  skip_before_action :verify_authenticity_token, if: -> { request.format.json? }
  skip_before_action :require_authentication, only: [:index, :show, :review_events, :review_events_hub, :deployments, :stages, :sop]
  before_action :require_admin, except: [:index, :show, :review_events, :review_events_hub, :deployments, :stages, :sop]
  before_action :set_task, only: [:show, :review_events, :edit, :update, :destroy, :comment]

  def reorder
    slugs = params[:slugs]
    return render json: { error: "slugs required" }, status: :unprocessable_entity unless slugs.is_a?(Array)

    rescue_and_log(target: nil) do
      # `slugs` arrives top-to-bottom in DOM order. Under the `position DESC` sort
      # the top card must hold the HIGHEST rank, so the first slug gets the largest
      # value; 100-spacing leaves gaps for the next drag insert (News/Content scheme).
      slugs.each_with_index do |slug, index|
        Task.where(slug: slug).update_all(position: (slugs.length - index) * 100)
      end
      render json: { success: true }
    end
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # /tasks — Workflow 1 (Build, feature agent): designed → building → blocked → submitted.
  def index
    load_board
  end

  # /deployments — Workflow 2 (Deploy, DevOps): submitted → reviewed → assembled →
  # shipped, led by the current-release module.
  def deployments
    load_board
    @current_release = Release.current
    @last_release = Release.last_shipped
    @release_duration_dashboard = Release::DurationCache.dashboard(limit: 3)
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
    @task_events = @task.task_events.chronological.to_a
    @agents = Agent.order(:position)
    @active_review_intent = @task.open_intent_for("reviewed")
  end

  def review_events
    @task_events = @task.task_events.chronological.to_a
    @review_events = @task.review_check_in_events
    load_review_process_context
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
    tasks = Task.ordered.includes(:task_events)
    agent_filter = params[:agent_slug].presence || params[:agent].presence
    tasks = tasks.where(agent_slug: agent_filter) if agent_filter
    stage_filter = params[:stage].presence
    tasks = tasks.where(stage: stage_filter) if Task::STAGES.include?(stage_filter)
    load_board_task_conversation(tasks)
    @tasks_by_stage = tasks.group_by(&:stage)
    @agents = Agent.order(:position)
  end

  def load_board_task_conversation(tasks)
    task_slugs = tasks.map(&:slug)
    activities = Activity.where(task_slug: task_slugs, activity_type: Activity::TASK_CONVERSATION_TYPES)
    @task_activity_counts = activities.group(:task_slug).count
    @latest_task_activities = activities.recent.each_with_object({}) do |activity, memo|
      memo[activity.task_slug] ||= activity
    end
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
