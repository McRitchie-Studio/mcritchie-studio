class TasksController < ApplicationController
  skip_before_action :verify_authenticity_token, if: -> { request.format.json? }
  skip_before_action :require_authentication, only: [:index, :show]
  before_action :require_admin, except: [:index, :show]
  before_action :set_task, only: [:show, :edit, :update, :destroy, :queue, :start, :complete, :fail_task, :archive, :comment]

  def reorder
    slugs = params[:slugs]
    return render json: { error: "slugs required" }, status: :unprocessable_entity unless slugs.is_a?(Array)

    rescue_and_log(target: nil) do
      slugs.each_with_index do |slug, index|
        Task.where(slug: slug).update_all(position: index)
      end
      render json: { success: true }
    end
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def index
    tasks = Task.ordered
    agent_filter = params[:agent_slug].presence || params[:agent].presence
    tasks = tasks.where(agent_slug: agent_filter) if agent_filter
    stage_filter = params[:stage].presence
    tasks = tasks.where(stage: stage_filter) if Task::STAGES.include?(stage_filter)
    @tasks_by_stage = tasks.group_by(&:stage)
    @agents = Agent.order(:position)
  end

  def show
    load_task_conversation
  end

  def new
    @task = Task.new
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

  def queue
    rescue_and_log(target: @task) do
      @task.queue!
      respond_to do |format|
        format.html { redirect_to task_path(@task.slug), notice: "Task queued." }
        format.json { render json: @task }
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to task_path(@task.slug), alert: e.message }
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def start
    rescue_and_log(target: @task) do
      @task.start!
      respond_to do |format|
        format.html { redirect_to task_path(@task.slug), notice: "Task started." }
        format.json { render json: @task }
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to task_path(@task.slug), alert: e.message }
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def complete
    rescue_and_log(target: @task) do
      @task.complete!
      respond_to do |format|
        format.html { redirect_to task_path(@task.slug), notice: "Task completed." }
        format.json { render json: @task }
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to task_path(@task.slug), alert: e.message }
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def fail_task
    rescue_and_log(target: @task) do
      @task.fail!(params[:error_message])
      respond_to do |format|
        format.html { redirect_to task_path(@task.slug), notice: "Task marked as failed." }
        format.json { render json: @task }
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to task_path(@task.slug), alert: e.message }
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def archive
    rescue_and_log(target: @task) do
      @task.archive!
      respond_to do |format|
        format.html { redirect_to task_path(@task.slug), notice: "Task archived." }
        format.json { render json: @task }
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to task_path(@task.slug), alert: e.message }
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
        :branch,
        :pr_url,
        :local_url,
        :qa_url,
        :production_url,
        :release_train,
        :requires_release_conductor,
        :repositories,
        :risk_tags,
        :acceptance,
        :test_plan
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
