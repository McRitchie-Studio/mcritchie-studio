class SizingsController < ApplicationController
  before_action :require_admin, only: [:update]
  before_action :set_task

  def show
  end

  def update
    rescue_and_log(target: @task) do
      @task.update!(sizing_params)
      respond_to do |format|
        format.html { redirect_to task_sizing_path(@task), notice: "Sizes updated." }
        format.json { render json: @task }
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_to task_sizing_path(@task), alert: e.message }
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  private

  def set_task
    @task = Task.find_by(slug: params[:task_slug])
    return redirect_to tasks_path, alert: "Task not found" unless @task
  end

  def sizing_params
    params.require(:task).permit(:pm_size, :po_size, :dev_size, :actual_size, :requires_migration)
  end
end
