module Api
  module V1
    class ActivitiesController < BaseController
      def index
        activities = Activity.recent
        activities = activities.where(agent_slug: params[:agent_slug]) if params[:agent_slug].present?
        activities = activities.for_task(params[:task_slug]) if params[:task_slug].present?
        activities = activities.by_type(params[:activity_type]) if params[:activity_type].present?
        result = paginate(activities)
        render_data(result[:records], meta: result[:meta])
      end

      def create
        activity = Activity.new(activity_params)
        rescue_and_log(target: activity) do
          activity.save!
          render_data(activity, status: :created)
        end
      rescue StandardError => e
        render_error(e.message)
      end

      private

      def activity_params
        params.permit(:agent_slug, :activity_type, :description, :task_slug, metadata: {})
      end
    end
  end
end
