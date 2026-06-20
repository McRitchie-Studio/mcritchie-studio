module Api
  module V1
    class TasksController < BaseController
      def index
        tasks = Task.recent
        tasks = tasks.by_stage(params[:stage]) if params[:stage].present?
        tasks = tasks.where(agent_slug: params[:agent_slug]) if params[:agent_slug].present?
        result = paginate(tasks)
        render_data(result[:records], meta: result[:meta])
      end

      def show
        task = Task.find_by!(slug: params[:slug])
        render_data(task)
      end

      def create
        task = Task.new(task_params)
        rescue_and_log(target: task) do
          task.save!
          render_data(task, status: :created)
        end
      rescue StandardError => e
        render_error(e.message)
      end

      def update
        task = Task.find_by!(slug: params[:slug])
        rescue_and_log(target: task) do
          task.update!(task_params)
          render_data(task)
        end
      rescue StandardError => e
        render_error(e.message)
      end

      def destroy
        task = Task.find_by!(slug: params[:slug])
        rescue_and_log(target: task) do
          task.destroy!
          head :no_content
        end
      rescue StandardError => e
        render_error(e.message)
      end

      private

      def task_params
        permitted = params.permit(
          :title,
          :description,
          :priority,
          :agent_slug,
          :stage,
          required_skills: [],
          metadata: {}
        )
        attrs = permitted.except(:devops).to_h
        return attrs unless params[:devops]

        attrs["metadata"] = attrs.fetch("metadata", {}).to_h.merge(
          "devops" => Task.normalize_devops_metadata(raw_devops_params)
        )
        attrs
      end

      def raw_devops_params
        raw = params[:devops]
        raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
      end
    end
  end
end
