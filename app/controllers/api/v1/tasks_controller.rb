module Api
  module V1
    class TasksController < BaseController
      before_action :capture_task_event_context, only: [:create, :update]

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

      # Drain an optional `event` payload into Current so Task#record_stage_event
      # can annotate the transition it's about to write with the agent-reported,
      # per-transition usage. The deterministic from/to/duration spine is recorded
      # regardless; this only adds model/tokens/cost when the caller supplies them.
      def capture_task_event_context
        event = params[:event]
        Current.task_event_source = (event && event[:source].presence) || "api"
        return if event.blank?

        Current.task_event_actor      = event[:actor].presence
        Current.task_event_model      = event[:model].presence
        Current.task_event_tokens_in  = event[:tokens_in].presence&.to_i
        Current.task_event_tokens_out = event[:tokens_out].presence&.to_i
        Current.task_event_cost       = event[:cost].presence&.to_d
      end

      def task_params
        permitted = params.permit(
          :slug, # honored only on create (attr_readonly on the model); custom readable handle
          :title,
          :description,
          :priority,
          :agent_slug,
          :stage,
          required_skills: [],
          metadata: {}
        )
        attrs = permitted.except(:devops).to_h
        # slug is honored only on create; on update params[:slug] is the URL id and
        # assigning it would trip attr_readonly. Drop it so updates never touch slug.
        attrs.delete("slug") unless action_name == "create"
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
